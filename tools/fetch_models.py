"""
从 pcb-component-detection-models 仓库的 Release 下载推理用的 ONNX 模型。

模型体积较大（38–109 MB），不适合放进 git，统一从 Release 取：
    https://github.com/C6H8FNO4/pcb-component-detection-models/releases

用法：
    python tools/fetch_models.py              # 缺什么下什么
    python tools/fetch_models.py --force      # 全部重下
    python tools/fetch_models.py --check      # 只校验，不下载
    python tools/fetch_models.py --list       # 列出清单

环境变量：
    PCB_MODELS_REPO    覆盖仓库（默认 C6H8FNO4/pcb-component-detection-models）
    PCB_MODELS_TAG     覆盖 tag（默认 v1）
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
import urllib.request
from pathlib import Path

REPO = os.environ.get("PCB_MODELS_REPO", "C6H8FNO4/pcb-component-detection-models")
TAG = os.environ.get("PCB_MODELS_TAG", "v1")

# Windows 控制台默认 GBK，避免中文/符号打印崩掉
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
except Exception:
    pass

ROOT = Path(__file__).resolve().parent.parent
MODEL_DIR = ROOT / "models"

# 文件名 → (资产名, 说明)
MODELS = [
    ("solder_yolo26m_800.onnx", "solder_yolo26m_800.onnx", "焊接/装配缺陷 9 类 imgsz 800（81.8 MB）"),
    ("bare_yolo26s_1024.onnx", "bare_yolo26s_1024.onnx", "裸板缺陷 7 类 imgsz 1024（38.4 MB）"),
    ("seg_yolov8m_pcb.onnx", "seg_yolov8m_pcb.onnx", "PCB 缺陷分割 4 类 imgsz 640（109.1 MB）"),
]


def sha256_of(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def url_for(asset: str) -> str:
    return f"https://github.com/{REPO}/releases/download/{TAG}/{asset}"


def download(asset: str, dest: Path) -> bool:
    tmp = dest.with_suffix(dest.suffix + ".part")
    url = url_for(asset)
    print(f"    下载 {asset} …", flush=True)
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "pcb-fetch/1.0"})
        with urllib.request.urlopen(req, timeout=60) as r, tmp.open("wb") as f:
            total = int(r.headers.get("Content-Length") or 0)
            done = 0
            while True:
                buf = r.read(1 << 20)
                if not buf:
                    break
                f.write(buf)
                done += len(buf)
                if total:
                    pct = done * 100 // total
                    print(f"\r    {pct:3d}%  {done/1e6:6.1f}/{total/1e6:.1f} MB", end="", flush=True)
        print()
        tmp.replace(dest)
        return True
    except Exception as e:
        print(f"\n    [失败] {asset}: {type(e).__name__}: {e}")
        tmp.unlink(missing_ok=True)
        return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true", help="已存在也重下")
    ap.add_argument("--check", action="store_true", help="只检查是否存在，不下载")
    ap.add_argument("--list", action="store_true", help="列出模型清单")
    args = ap.parse_args()

    if args.list:
        for name, asset, desc in MODELS:
            p = MODEL_DIR / name
            mark = "存在" if p.exists() else "缺失"
            print(f"  [{mark}] {name:26s} {desc}")
            print(f"           {url_for(asset)}")
        return 0

    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    print(f"模型来源: https://github.com/{REPO}/releases/tag/{TAG}")
    print(f"目标目录: {MODEL_DIR}")

    missing = 0
    for name, asset, desc in MODELS:
        dest = MODEL_DIR / name
        if dest.exists() and not args.force:
            size = dest.stat().st_size / 1e6
            print(f"  [已有] {name}  ({size:.1f} MB)")
            continue
        if args.check:
            print(f"  [缺失] {name}  {desc}")
            missing += 1
            continue
        print(f"  获取 {name}  {desc}")
        if not download(asset, dest):
            missing += 1
            continue
        print(f"  [完成] {name}  ({dest.stat().st_size/1e6:.1f} MB)")

    if missing:
        print(f"\n有 {missing} 个模型不可用。手动下载地址:")
        for name, asset, _ in MODELS:
            if not (MODEL_DIR / name).exists():
                print(f"  {url_for(asset)}")
        return 1

    print("\n模型齐全")
    return 0


if __name__ == "__main__":
    sys.exit(main())