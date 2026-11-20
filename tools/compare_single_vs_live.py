"""
对比：单张检测路径 vs 实时检测路径，精度差多少。

同一模型、同一 imgsz、同一逐类阈值、同一 IoU，只有"输入图"不同：
  A 单张：原图直接送（网页 /api/predict）
  B 实时：长边缩到 1600 + JPEG q85（网页 /api/detect 的抓帧参数）
  C 实时（低清源）：长边缩到 1280 + JPEG q85（720p 级视频源）
"""
import os
os.environ.setdefault("YOLO_CONFIG_DIR", r"C:\Users\yuzij\Documents\app\webapp\.ultralytics")
os.environ.setdefault("MPLBACKEND", "Agg")

import glob
import cv2
import numpy as np
from ultralytics import YOLO

ONNX = r"C:\Users\yuzij\Documents\app\webapp\models\solder_yolo26m_800.onnx"
IMGS = sorted(glob.glob(r"C:\Users\yuzij\Documents\app\android\testdata\test_solder\*.jpg"))
IMGSZ = 800
IOU = 0.45
PER_CLASS = {
    "insufficient_solder": 0.297, "excess_solder": 0.349, "solder_bridge": 0.417,
    "solder_void": 0.249, "missing_component": 0.381, "shifted_component": 0.389,
    "burn": 0.224, "physical_damage": 0.214, "oxidation": 0.228,
}
MIN_CONF = min(PER_CLASS.values())

model = YOLO(ONNX)


def jpeg_roundtrip(img, quality):
    ok, enc = cv2.imencode(".jpg", img, [int(cv2.IMWRITE_JPEG_QUALITY), quality])
    return cv2.imdecode(enc, cv2.IMREAD_COLOR)


def resize_long(img, target):
    h, w = img.shape[:2]
    s = min(1.0, target / max(h, w))
    if s >= 1.0:
        return img
    return cv2.resize(img, (int(round(w * s)), int(round(h * s))), interpolation=cv2.INTER_AREA)


def detect(img):
    res = model.predict(img, conf=MIN_CONF, iou=IOU, imgsz=IMGSZ, verbose=False)[0]
    keep = []
    for b in res.boxes:
        cid = int(b.cls.item())
        name = model.names[cid]
        s = float(b.conf.item())
        if s >= PER_CLASS.get(name, 0.228):
            keep.append((name, round(s, 3), [round(v) for v in b.xyxy[0].tolist()]))
    return keep


def summarize(keep):
    if not keep:
        return 0, 0.0
    return len(keep), max(k[1] for k in keep)


print(f"{'图片':46s} {'路径':26s} {'框数':>4s} {'最高分':>7s}")
print("-" * 92)

tot = {"A": [0, 0.0], "B": [0, 0.0], "C": [0, 0.0]}
for p in IMGS:
    base = cv2.imread(p)
    if base is None:
        continue
    variants = {
        "A 单张(原图, q90)":          jpeg_roundtrip(base, 90),
        "B 实时(长边1600, q85)":      jpeg_roundtrip(resize_long(base, 1600), 85),
        "C 实时(长边1280, q85)":      jpeg_roundtrip(resize_long(base, 1280), 85),
    }
    name = os.path.basename(p)[:44]
    for label, img in variants.items():
        keep = detect(img)
        n, mx = summarize(keep)
        key = label[0]
        tot[key][0] += n
        tot[key][1] = max(tot[key][1], mx)
        print(f"{name:46s} {label:26s} {n:>4d} {mx:>7.3f}  {img.shape[1]}x{img.shape[0]}")

print("-" * 92)
print(f"{'合计框数':46s} {'A 单张':26s} {tot['A'][0]:>4d} {tot['A'][1]:>7.3f}")
print(f"{'':46s} {'B 实时(1600)':26s} {tot['B'][0]:>4d} {tot['B'][1]:>7.3f}")
print(f"{'':46s} {'C 实时(1280)':26s} {tot['C'][0]:>4d} {tot['C'][1]:>7.3f}")