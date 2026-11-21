#!/usr/bin/env bash
# PCB 缺陷检测 Web 服务 —— 安装脚本（可选 GPU 后端，Linux / macOS）
#
# 用法：
#   bash install-gpu.sh                       # 菜单选择
#   bash install-gpu.sh --backend cu124       # 直接指定
#   bash install-gpu.sh --backend cpu --no-start
#   bash install-gpu.sh --backend cpu --skip-deps --venv ../venv310
#
# 选项：
#   --backend cpu|cu128|cu126|cu124|cu121
#   --venv <dir>      复用已有虚拟环境
#   --mirror          依赖走清华镜像
#   --skip-deps       跳过 pip 安装（环境已就绪时）
#   --upgrade-pip     顺便升级 pip
#   --no-start        只安装不启动
#   --force           强制重装 torch

set -euo pipefail
cd "$(dirname "$0")"

MIRROR_URL="https://pypi.tuna.tsinghua.edu.cn/simple"
CUDA_KEYS=(cu128 cu126 cu124 cu121)
CUDA_NAMES=("CUDA 12.8" "CUDA 12.6" "CUDA 12.4" "CUDA 12.1")
CUDA_MINDRV=(570 560 550 530)

BACKEND=""; VENV=""; MIRROR=0; SKIP_DEPS=0; UPGRADE_PIP=0; NO_START=0; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --backend) BACKEND="${2:-}"; shift 2 ;;
    --venv) VENV="${2:-}"; shift 2 ;;
    --mirror) MIRROR=1; shift ;;
    --skip-deps) SKIP_DEPS=1; shift ;;
    --upgrade-pip) UPGRADE_PIP=1; shift ;;
    --no-start) NO_START=1; shift ;;
    --force) FORCE=1; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

cyan(){ printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok(){   printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
warn(){ printf '    \033[33m[!]  %s\033[0m\n' "$1"; }
die(){  printf '\n\033[31m[失败] %s\033[0m\n' "$1"; exit 1; }

printf '==========================================\n'
printf '  PCB 缺陷检测 · Web 安装（可选 GPU）\n'
printf '==========================================\n'
printf '目录: %s\n' "$PWD"

# ---------------------------------------------------------------- 1. 探测显卡
cyan "探测显卡"
GPU_NAME=""; DRV=""
if command -v nvidia-smi >/dev/null 2>&1; then
  LINE=$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null | head -1 || true)
  GPU_NAME=$(echo "$LINE" | awk -F', *' '{print $1}')
  DRV=$(echo "$LINE" | awk -F', *' '{print $2}')
  VRAM=$(echo "$LINE" | awk -F', *' '{print $3}')
fi

RECOMMEND=""
if [ -n "$GPU_NAME" ]; then
  ok "NVIDIA $GPU_NAME · 驱动 $DRV · 显存 ${VRAM:-?}"
  MAJ=${DRV%%.*}
  for i in "${!CUDA_KEYS[@]}"; do
    if [ "$MAJ" -ge "${CUDA_MINDRV[$i]}" ]; then RECOMMEND="${CUDA_KEYS[$i]}"; break; fi
  done
  if [ -n "$RECOMMEND" ]; then
    for i in "${!CUDA_KEYS[@]}"; do
      [ "${CUDA_KEYS[$i]}" = "$RECOMMEND" ] && ok "按驱动版本推荐: ${CUDA_NAMES[$i]}"
    done
  else
    warn "驱动偏旧（主版本 $MAJ < 530），只能 CPU 版或先升级驱动"; RECOMMEND="cpu"
  fi
else
  warn "没检测到 NVIDIA 显卡 —— 只能 CPU 版"; RECOMMEND="cpu"
fi

# ---------------------------------------------------------------- 2. 选后端
if [ -n "$BACKEND" ]; then
  printf '\n使用命令行指定后端: %s\n' "$BACKEND"
else
  printf '\n选择 PyTorch 后端（GPU 版下载 2–3 GB，CPU 版约 200 MB）：\n'
  printf '  [0] CPU         —— 无显卡也能跑\n'
  for i in "${!CUDA_KEYS[@]}"; do
    TAG=""
    [ "${CUDA_KEYS[$i]}" = "$RECOMMEND" ] && TAG="   <= 推荐"
    printf '  [%d] %-11s —— 驱动 >= %s%s\n' "$((i+1))" "${CUDA_NAMES[$i]}" "${CUDA_MINDRV[$i]}" "$TAG"
  done
  DEF="${RECOMMEND:-cpu}"
  printf '\n输入编号（回车 = 自动，即 %s）: ' "$DEF"
  read -r ANS
  if [ -z "$ANS" ]; then BACKEND="$DEF"
  elif [ "$ANS" = "0" ]; then BACKEND="cpu"
  elif [ "$ANS" -ge 1 ] 2>/dev/null && [ "$ANS" -le "${#CUDA_KEYS[@]}" ]; then
    BACKEND="${CUDA_KEYS[$((ANS-1))]}"
  else die "无效输入: $ANS"; fi
fi

CHOSEN_LABEL=""; TORCH_INDEX=""
if [ "$BACKEND" = "cpu" ]; then
  TORCH_INDEX="https://download.pytorch.org/whl/cpu"; CHOSEN_LABEL="CPU"
else
  FOUND=0
  for i in "${!CUDA_KEYS[@]}"; do
    if [ "${CUDA_KEYS[$i]}" = "$BACKEND" ]; then
      TORCH_INDEX="https://download.pytorch.org/whl/$BACKEND"; CHOSEN_LABEL="${CUDA_NAMES[$i]}"; FOUND=1
      MAJ=${DRV%%.*}; MAJ=${MAJ:-0}
      if [ "$MAJ" -lt "${CUDA_MINDRV[$i]}" ] && [ -n "$DRV" ]; then
        warn "驱动 $DRV 低于 $CHOSEN_LABEL 的建议值 ${CUDA_MINDRV[$i]}，装完可能 cuda 不可用"
      fi
    fi
  done
  [ "$FOUND" = "1" ] || die "未知后端: $BACKEND"
fi
ok "后端: $CHOSEN_LABEL"

# ---------------------------------------------------------------- 3. Python
cyan "查找 Python（需要 3.9 – 3.12）"
PY=""
for cand in ${PYTHON:-} python3.12 python3.11 python3.10 python3.9 python3 python; do
  [ -z "$cand" ] && continue
  command -v "$cand" >/dev/null 2>&1 || continue
  ver=$("$cand" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)
  [ -z "$ver" ] && continue
  maj=${ver%%.*}; min=${ver##*.}
  if [ "$maj" = "3" ] && [ "$min" -ge 9 ] && [ "$min" -le 12 ]; then PY="$cand"; ok "使用 $cand (Python $ver)"; break; fi
  warn "跳过 $cand (Python $ver)"
done
[ -n "$PY" ] || die "找不到 Python 3.9–3.12（Debian/Ubuntu 需要 python3-venv）"

# ---------------------------------------------------------------- 4. 虚拟环境
cyan "准备虚拟环境"
[ -z "$VENV" ] && VENV="$PWD/.venv"
if [ -x "$VENV/bin/python" ]; then ok "复用 $VENV"
else "$PY" -m venv "$VENV" || die "虚拟环境创建失败"; ok "已创建 $VENV"; fi
VPY="$VENV/bin/python"

PIP_COMMON=(--prefer-binary --timeout 60 --retries 3 --no-input)

if [ "$SKIP_DEPS" = "1" ]; then
  warn "已指定 --skip-deps：跳过所有 pip 安装"
else
  if [ "$UPGRADE_PIP" = "1" ]; then
    cyan "升级 pip"
    "$VPY" -m pip install --upgrade pip --timeout 60 --retries 2 -q || warn "pip 升级失败，继续"
  fi

  cyan "安装 PyTorch（$CHOSEN_LABEL）"
  CUR=$("$VPY" -c 'import torch;print(torch.__version__)' 2>/dev/null || true)
  [ -n "$CUR" ] && printf '    当前: torch %s\n' "$CUR"
  SAME=0
  if [ "$BACKEND" = "cpu" ] && echo "$CUR" | grep -q '+cpu'; then SAME=1; fi
  if [ "$BACKEND" != "cpu" ] && echo "$CUR" | grep -q "+$BACKEND"; then SAME=1; fi
  if [ "$SAME" = "1" ] && [ "$FORCE" != "1" ]; then
    ok "已是 $CHOSEN_LABEL 版本，跳过（要重装加 --force）"
  else
    printf '    从 %s 下载，耐心等待…\n' "$TORCH_INDEX"
    "$VPY" -m pip install "${PIP_COMMON[@]}" torch torchvision --index-url "$TORCH_INDEX" \
      || die "PyTorch 安装失败（可换 --backend cu124 或检查 download.pytorch.org）"
    ok "PyTorch 安装完成"
  fi

  cyan "安装 ultralytics / flask / opencv"
  ARGS=(install "${PIP_COMMON[@]}" -r requirements.txt)
  [ "$MIRROR" = "1" ] && ARGS+=(-i "$MIRROR_URL")
  if ! "$VPY" -m pip "${ARGS[@]}"; then
    [ "$MIRROR" = "1" ] && die "依赖安装失败"
    warn "直连 PyPI 失败，改用清华镜像重试…"
    "$VPY" -m pip install "${PIP_COMMON[@]}" -r requirements.txt -i "$MIRROR_URL" || die "依赖安装失败"
  fi
  ok "依赖就绪"
fi

# ---------------------------------------------------------------- 5. 自检
cyan "运行时自检"
"$VPY" - <<'PY' || true
import torch
print("    torch        :", torch.__version__)
print("    cuda 可用    :", torch.cuda.is_available())
if torch.cuda.is_available():
    print("    GPU          :", torch.cuda.get_device_name(0))
    print("    显存         :", round(torch.cuda.get_device_properties(0).total_memory/1024**3, 1), "GB")
    print("    CUDA runtime :", torch.version.cuda)
try:
    import ultralytics, flask, cv2
    print("    ultralytics  :", ultralytics.__version__)
except Exception as e:
    print("    缺依赖       :", e)
PY

# ---------------------------------------------------------------- 6. 模型
cyan "检查模型权重"
for f in solder_yolo26m_800.onnx bare_yolo26s_1024.onnx; do
  if [ -f "models/$f" ]; then ok "$f ($(du -h "models/$f" | cut -f1))"
  else warn "缺少 models/$f —— 见 models/README.md"; fi
done

# ---------------------------------------------------------------- 7. 启动
if [ "$NO_START" = "1" ]; then
  printf '\n安装完成。启动：\n  %s app_flask.py\n' "$VPY"
  exit 0
fi
printf '\n安装完成，正在启动服务…（Ctrl+C 停止）\n\n'
export YOLO_CONFIG_DIR="$PWD/.ultralytics"
exec "$VPY" app_flask.py