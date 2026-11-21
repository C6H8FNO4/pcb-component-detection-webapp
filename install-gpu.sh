#!/usr/bin/env bash
# PCB 缺陷检测 Web 服务 —— 安装脚本（CPU / GPU，Linux / macOS）
#
# 推理用 onnxruntime，不需要 torch：
#   CPU → onnxruntime       GPU → onnxruntime-gpu（需系统已装 CUDA 12.x + cuDNN 9）
#
# 用法：
#   bash install-gpu.sh              # 交互选择
#   bash install-gpu.sh --gpu        # 直接装 GPU 版
#   bash install-gpu.sh --cpu --mirror --no-start

set -euo pipefail
cd "$(dirname "$0")"

MIRROR_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
USE_GPU=0; CHOICE=""; VENV=""; MIRROR=0; SKIP_DEPS=0; NO_START=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gpu) USE_GPU=1; CHOICE="gpu"; shift ;;
    --cpu) USE_GPU=0; CHOICE="cpu"; shift ;;
    --venv) VENV="${2:-}"; shift 2 ;;
    --mirror) MIRROR=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --no-start) NO_START=1; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

cyan(){ printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok(){   printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
warn(){ printf '    \033[33m[!]  %s\033[0m\n' "$1"; }
die(){  printf '\n\033[31m[失败] %s\033[0m\n' "$1"; exit 1; }

printf '==========================================\n'
printf '  PCB 缺陷检测 · Web 安装（CPU / GPU）\n'
printf '==========================================\n'

cyan "探测显卡"
HAS_GPU=0
if command -v nvidia-smi >/dev/null 2>&1; then
  LINE=$(nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
  if [ -n "$LINE" ]; then
    HAS_GPU=1
    ok "NVIDIA ${LINE}"
    warn "GPU 推理需要 CUDA 12.x + cuDNN 9，否则请用 CPU 版"
  fi
fi
[ "$HAS_GPU" = "0" ] && warn "没检测到 NVIDIA 显卡 —— 只能用 CPU 版"

if [ -z "$CHOICE" ]; then
  if [ "$HAS_GPU" = "1" ]; then
    printf '\n选择推理后端：\n  [0] CPU（onnxruntime，约 60 MB）\n  [1] GPU（onnxruntime-gpu，约 250 MB）\n回车=0: '
    read -r ANS
    [ "${ANS:-0}" = "1" ] && USE_GPU=1
  fi
fi

if [ "$USE_GPU" = "1" ]; then PKG="onnxruntime-gpu"; else PKG="onnxruntime"; fi
ok "后端: $([ "$USE_GPU" = "1" ] && echo GPU || echo CPU)  →  $PKG"

cyan "查找 Python（3.9 – 3.12）"
PY=""
for cand in ${PYTHON:-} python3.12 python3.11 python3.10 python3.9 python3 python; do
  [ -z "$cand" ] && continue
  command -v "$cand" >/dev/null 2>&1 || continue
  ver=$("$cand" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)
  [ -z "$ver" ] && continue
  maj=${ver%%.*}; min=${ver##*.}
  if [ "$maj" = "3" ] && [ "$min" -ge 9 ] && [ "$min" -le 12 ]; then PY="$cand"; ok "使用 $cand ($ver)"; break; fi
done
[ -n "$PY" ] || die "找不到 Python 3.9–3.12（Debian/Ubuntu 需要 python3-venv）"

cyan "准备虚拟环境"
[ -z "$VENV" ] && VENV="$PWD/.venv"
if [ -x "$VENV/bin/python" ]; then ok "复用 $VENV"; else "$PY" -m venv "$VENV" || die "venv 创建失败"; ok "已创建"; fi
VPY="$VENV/bin/python"

if [ "$SKIP_DEPS" = "1" ]; then
  warn "已指定 --skip-deps：跳过 pip 安装"
else
  PIP_COMMON=(--prefer-binary --timeout 60 --retries 3 --no-input)
  IDX=(); [ "$MIRROR" = "1" ] && IDX=(-i "$MIRROR_URL")

  cyan "安装 $PKG"
  "$VPY" -m pip install "${PIP_COMMON[@]}" "${IDX[@]}" "$PKG" || die "$PKG 安装失败（可加 --mirror）"
  cyan "安装其余依赖"
  "$VPY" -m pip install "${PIP_COMMON[@]}" "${IDX[@]}" -r requirements.txt || die "依赖安装失败（可加 --mirror）"
  ok "依赖就绪"
fi

cyan "运行时自检"
"$VPY" - <<'PY' || true
import onnxruntime as ort
prov = ort.get_available_providers()
print("    onnxruntime :", ort.__version__)
print("    providers   :", ", ".join(prov))
print("    cuda 可用   :", "CUDAExecutionProvider" in prov)
PY

cyan "检查模型权重"
for f in solder_yolo26m_800.onnx bare_yolo26s_1024.onnx; do
  if [ -f "models/$f" ]; then ok "$f ($(du -h "models/$f" | cut -f1))"; else warn "缺少 models/$f"; fi
done

if [ "$NO_START" = "1" ]; then
  printf '\n安装完成。启动：\n  %s app_flask.py\n' "$VPY"
  exit 0
fi
printf '\n安装完成，正在启动服务…（Ctrl+C 停止）\n\n'
exec "$VPY" app_flask.py