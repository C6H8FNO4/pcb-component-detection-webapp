#!/usr/bin/env bash
# PCB 缺陷检测 —— Web 服务安装脚本（Linux / macOS）
#
# 用法：
#   bash install.sh            # 安装并启动
#   bash install.sh --no-start # 只安装
#
# 环境变量：
#   PYTHON=python3.11          # 指定解释器
#   PIP_INDEX_URL=...          # 换镜像

set -euo pipefail

cd "$(dirname "$0")"

cyan() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
warn() { printf '    \033[33m[!]  %s\033[0m\n' "$1"; }
die()  { printf '\n\033[31m[失败] %s\033[0m\n' "$1"; exit 1; }

NO_START=0
for a in "$@"; do
  case "$a" in
    --no-start) NO_START=1 ;;
    *) die "未知参数: $a" ;;
  esac
done

printf '==========================================\n'
printf '  PCB 缺陷检测 · Web 服务安装\n'
printf '==========================================\n'
printf '目录: %s\n' "$PWD"

# ---------------------------------------------------------------- 1. 找 Python
cyan "查找 Python（需要 3.9 – 3.12）"

find_py() {
  for cand in "${PYTHON:-}" python3.12 python3.11 python3.10 python3.9 python3 python; do
    [ -z "$cand" ] && continue
    command -v "$cand" >/dev/null 2>&1 || continue
    ver=$("$cand" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || true)
    [ -z "$ver" ] && continue
    maj=${ver%%.*}; min=${ver##*.}
    if [ "$maj" = "3" ] && [ "$min" -ge 9 ] && [ "$min" -le 12 ]; then
      PY="$cand"; PYVER="$ver"
      ok "使用 $cand (Python $ver)"
      return 0
    fi
    warn "跳过 $cand (Python $ver，torch 不支持)"
  done
  return 1
}

find_py || die "找不到 Python 3.9–3.12。请安装：apt install python3.11 python3.11-venv（或 pyenv / brew install python@3.11）"

# ---------------------------------------------------------------- 2. 虚拟环境
cyan "创建虚拟环境 .venv"
if [ -x ".venv/bin/python" ]; then
  ok "已存在，复用"
else
  "$PY" -m venv .venv || die "虚拟环境创建失败（Debian/Ubuntu 需先装 python3-venv）"
  ok "已创建 .venv"
fi

.venv/bin/python -m pip install --upgrade pip --quiet
ok "pip $($(.venv/bin/python -m pip --version) | awk '{print $2}')"

# ---------------------------------------------------------------- 3. 依赖
cyan "安装 PyTorch（CPU 版）"
.venv/bin/python -m pip install --quiet torch torchvision \
  --index-url https://download.pytorch.org/whl/cpu || die "PyTorch 安装失败"
ok "PyTorch 就绪"

cyan "安装其余依赖"
.venv/bin/python -m pip install --quiet -r requirements.txt || die "依赖安装失败"
ok "依赖安装完成"

cyan "自检"
.venv/bin/python - <<'PY'
import torch, ultralytics, flask, cv2
print(f"    torch {torch.__version__} / ultralytics {ultralytics.__version__} / cuda {torch.cuda.is_available()}")
PY

# ---------------------------------------------------------------- 4. 模型
cyan "检查模型权重"
for f in solder_yolo26m_800.onnx bare_yolo26s_1024.onnx; do
  if [ -f "models/$f" ]; then
    ok "$f ($(du -h "models/$f" | cut -f1))"
  else
    warn "缺少 models/$f —— 见 models/README.md"
  fi
done

# ---------------------------------------------------------------- 5. 启动
if [ "$NO_START" = "1" ]; then
  printf '\n安装完成。启动：\n  ./.venv/bin/python app_flask.py\n'
  exit 0
fi

printf '\n安装完成，正在启动服务… (Ctrl+C 停止)\n\n'
export YOLO_CONFIG_DIR="$PWD/.ultralytics"
exec .venv/bin/python app_flask.py