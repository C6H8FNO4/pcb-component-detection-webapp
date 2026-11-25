#!/usr/bin/env bash
# 把 Web 服务打包成 Linux / macOS 便携包（自带 Python，目标机无需安装任何东西）
#
# 用法：
#   bash tools/make_portable.sh                                  # 默认 CPU
#   bash tools/make_portable.sh --ort onnxruntime-gpu            # NVIDIA CUDA
#   bash tools/make_portable.sh --ort onnxruntime-rocm           # AMD ROCm（仅 Linux）
#   bash tools/make_portable.sh --out dist/foo.tar.gz
#
# 说明：
#   · Python 用 astral-sh/python-build-standalone 的 install_only 包，自包含
#   · 依赖装进这份 Python 自己的 site-packages，整体可搬移
#   · GPU 版只装 onnxruntime-gpu / onnxruntime-rocm，CUDA/ROCm 运行库仍需目标机自带
#     （数 GB，且授权不允许随包分发）

set -euo pipefail

ORT_PKG="onnxruntime"
OUT=""
WORK="build_portable_unix"
PBS_TAG="${PBS_TAG:-20261124}"
PBS_VER="${PBS_VER:-3.11.18}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ort) ORT_PKG="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --work) WORK="${2:?}"; shift 2 ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[ -z "$OUT" ] && OUT="$ROOT/dist/pcb-webapp-portable-$(uname -s | tr 'A-Z' 'a-z')-$(uname -m).tar.gz"

cyan(){ printf '\n\033[36m==> %s\033[0m\n' "$1"; }
ok(){   printf '    \033[32m[OK] %s\033[0m\n' "$1"; }
die(){  printf '\n\033[31m[失败] %s\033[0m\n' "$1"; exit 1; }

# ---------------------------------------------------------------- 选 PBS 资源
OS="$(uname -s)"; ARCH="$(uname -m)"
case "$OS-$ARCH" in
  Linux-x86_64)               TRIPLE="x86_64-unknown-linux-gnu" ;;
  Linux-aarch64|Linux-arm64)  TRIPLE="aarch64-unknown-linux-gnu" ;;
  Darwin-arm64)               TRIPLE="aarch64-apple-darwin" ;;
  Darwin-x86_64)              TRIPLE="x86_64-apple-darwin" ;;
  *) die "不支持的平台: $OS-$ARCH" ;;
esac
ASSET="cpython-${PBS_VER}+${PBS_TAG}-${TRIPLE}-install_only.tar.gz"
URL="https://github.com/astral-sh/python-build-standalone/releases/download/${PBS_TAG}/${ASSET}"

printf '==========================================\n'
printf '  PCB 缺陷检测 · 便携包构建\n'
printf '==========================================\n'
printf '平台: %s-%s  ·  Python: %s  ·  ORT: %s\n' "$OS" "$ARCH" "$PBS_VER" "$ORT_PKG"

PKG="$ROOT/$WORK/pcb-webapp-portable"
rm -rf "$PKG"
mkdir -p "$PKG"

# ---------------------------------------------------------------- 1. 便携 Python
cyan "下载便携 Python"
if [ ! -f "$ROOT/$WORK/pbs.tar.gz" ]; then
  mkdir -p "$ROOT/$WORK"
  curl -fsSL "$URL" -o "$ROOT/$WORK/pbs.tar.gz" || die "下载失败: $URL"
fi
ok "$(du -h "$ROOT/$WORK/pbs.tar.gz" | cut -f1)"

tar -xzf "$ROOT/$WORK/pbs.tar.gz" -C "$PKG"     # 解出 python/ 目录
[ -x "$PKG/python/bin/python3" ] || die "解压后找不到 python/bin/python3"
ok "python $("$PKG/python/bin/python3" -V 2>&1)"

# ---------------------------------------------------------------- 2. 模型
cyan "确保模型就绪"
"$PKG/python/bin/python3" tools/fetch_models.py || die "模型下载失败"

# ---------------------------------------------------------------- 3. 依赖
cyan "安装依赖（$ORT_PKG）"
PIP="$PKG/python/bin/python3 -m pip"
$PIP install --quiet --upgrade pip
# requirements.txt 里含 CPU 版 onnxruntime；这里先过滤掉它，
# 由 --ort 指定的包统一安装（macOS x64 等平台必须锁旧版本时尤其重要）
REQ_TMP="$(mktemp)"
grep -viE '^\s*onnxruntime\s*(==|>=|<=|<|>|~=|$)' requirements.txt > "$REQ_TMP" || true
$PIP install --quiet --prefer-binary --timeout 60 --retries 3 -r "$REQ_TMP"
rm -f "$REQ_TMP"
$PIP install --quiet --prefer-binary --timeout 120 --retries 3 "$ORT_PKG" \
  || die "$ORT_PKG 安装失败（该平台可能没有这个包）"
# 清理缓存与编译产物，压缩体积
$PIP cache purge >/dev/null 2>&1 || true
find "$PKG/python" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
ok "依赖就绪（$(du -sh "$PKG/python" | cut -f1)）"

# ---------------------------------------------------------------- 4. 应用文件
cyan "复制应用"
cp -f "$ROOT"/*.py "$PKG"/ 2>/dev/null || true
cp -rf "$ROOT/templates" "$PKG"/
mkdir -p "$PKG/models"
cp -f "$ROOT/models"/*.onnx "$ROOT/models/models.json" "$ROOT/models/README.md" "$PKG/models/" 2>/dev/null || true
ok "应用文件已复制"

# ---------------------------------------------------------------- 5. 启动脚本
cat > "$PKG/start.sh" <<'EOF'
#!/usr/bin/env bash
# 双击或在终端执行：./start.sh
cd "$(dirname "$0")" || exit 1
export PYTHONUTF8=1
export PYTHONIOENCODING=utf-8
export YOLO_CONFIG_DIR="$PWD/app/.ultralytics" 2>/dev/null || true
exec ./python/bin/python3 app_flask.py
EOF
chmod +x "$PKG/start.sh"
ok "start.sh 已写入"

# ---------------------------------------------------------------- 6. 自检
cyan "自检"
"$PKG/python/bin/python3" - <<'PY' || die "便携 python 自检失败"
import importlib.metadata as md
for p in ("onnxruntime", "onnxruntime-gpu", "onnxruntime-rocm", "onnxruntime-directml"):
    try:
        print(f"    {p:24s} {md.version(p)}")
    except Exception:
        pass
import flask, cv2, numpy
print("    flask", flask.__version__, "· cv2", cv2.__version__, "· numpy", numpy.__version__)
PY
ok "便携 python 可用"

# ---------------------------------------------------------------- 7. 打包
cyan "打包"
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
tar -czf "$OUT" -C "$ROOT/$WORK" pcb-webapp-portable
ok "产物 $OUT  ($(du -h "$OUT" | cut -f1))"