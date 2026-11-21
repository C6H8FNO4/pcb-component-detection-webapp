"""
冒烟测试：确认两个模型能正常加载并跑通推理。CI 和本地都能用（不需要 torch）。

用法：
    python tools/smoke_test.py
    python tools/smoke_test.py --fast
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from detector_ort import Detector  # noqa: E402

MODELS = [
    ("solder", "models/solder_yolo26m_800.onnx", 800),
    ("bare", "models/bare_yolo26s_1024.onnx", 1024),
]


def make_image(w: int = 1280, h: int = 960) -> np.ndarray:
    """合成一张"像板子"的图：深绿底 + 亮色焊点阵列（BGR）。"""
    img = np.full((h, w, 3), (40, 60, 40), np.uint8)
    for y in range(80, h - 60, 90):
        for x in range(80, w - 60, 100):
            img[y:y + 14, x:x + 14] = (200, 210, 200)
    img[h // 2:h // 2 + 30, w // 2:w // 2 + 30] = (60, 60, 220)
    return img


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--fast", action="store_true", help="每个模型只推理一次")
    args = ap.parse_args()

    cfg_path = ROOT / "models" / "models.json"
    cfg = json.loads(cfg_path.read_text(encoding="utf-8")) if cfg_path.exists() else {}

    img = make_image()
    print(f"测试图: {img.shape[1]}x{img.shape[0]}")

    failed = 0
    for key, rel, expect_size in MODELS:
        path = ROOT / rel
        if not path.exists():
            print(f"  [FAIL] {rel} 不存在")
            failed += 1
            continue
        try:
            c = cfg.get(key, {})
            det = Detector(str(path), per_class=c.get("per_class"),
                           global_conf=c.get("global", 0.25))
            runs = 1 if args.fast else 2
            res = None
            for _ in range(runs):
                res = det.predict(img, iou=0.45)

            status = "OK" if det.size == expect_size and len(det.names) > 0 else "FAIL"
            print(f"  [{status}] {key}: imgsz={det.size} · 类别 {len(det.names)} 个 "
                  f"· 推理 {res.ms:.0f} ms · 检出 {len(res.boxes)} · 最高分 {res.max_score:.3f}")
            if status == "FAIL":
                failed += 1
        except Exception as e:
            print(f"  [FAIL] {key}: {type(e).__name__}: {e}")
            failed += 1

    print()
    if failed:
        print(f"冒烟测试失败：{failed} 个模型")
        return 1
    print("冒烟测试通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())