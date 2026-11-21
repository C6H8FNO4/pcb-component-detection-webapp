"""
冒烟测试：确认两个模型能正常加载并跑通推理。CI 和本地都能用。

用法：
    python tools/smoke_test.py            # 跑全部模型
    python tools/smoke_test.py --fast     # 每模型只跑一次推理
"""
from __future__ import annotations

import argparse
import sys
import time

import numpy as np
from ultralytics import YOLO

MODELS = [
    ("models/solder_yolo26m_800.onnx", "solder 焊接缺陷 9 类", 800),
    ("models/bare_yolo26s_1024.onnx", "bare 裸板缺陷 7 类", 1024),
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
    ap.add_argument("--fast", action="store_true")
    args = ap.parse_args()

    img = make_image()
    print(f"测试图: {img.shape[1]}x{img.shape[0]}")

    failed = 0
    for path, label, imgsz in MODELS:
        try:
            t0 = time.perf_counter()
            model = YOLO(path)
            load_s = time.perf_counter() - t0

            runs = 1 if args.fast else 2
            times = []
            res = None
            for _ in range(runs):
                t = time.perf_counter()
                res = model.predict(img, conf=0.2, iou=0.45, imgsz=imgsz, verbose=False)[0]
                times.append((time.perf_counter() - t) * 1000)

            n_cls = len(model.names)
            n_box = len(res.boxes) if res.boxes is not None else 0
            print(f"  [OK] {label}")
            print(f"       类别 {n_cls} 个 · imgsz {imgsz} · 加载 {load_s*1000:.0f} ms "
                  f"· 推理 {min(times):.0f} ms · 检出 {n_box} 个框")
            if n_cls == 0:
                print("       [FAIL] 类别数为 0，模型元数据可能损坏")
                failed += 1
        except Exception as e:
            print(f"  [FAIL] {label}: {type(e).__name__}: {e}")
            failed += 1

    print()
    if failed:
        print(f"冒烟测试失败：{failed} 个模型")
        return 1
    print("冒烟测试通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())