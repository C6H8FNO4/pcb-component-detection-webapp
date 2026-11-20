"""
对照：同一个模型，.pt(fp16 权重) 与 ONNX(fp32) 在相同输入尺寸下的输出差异。
目的：验证“82MB 和 44MB 精度有没有区别”。
"""
import os
os.environ.setdefault("YOLO_CONFIG_DIR", r"C:\Users\yuzij\Documents\app\webapp\.ultralytics")
os.environ.setdefault("MPLBACKEND", "Agg")

import glob
import numpy as np
from ultralytics import YOLO

PT = r"C:\Users\yuzij\Documents\app\webapp\models\solder_yolo26m.pt"
ONNX = r"C:\Users\yuzij\Documents\app\webapp\models\solder_yolo26m_640.onnx"
IMGS = sorted(glob.glob(r"C:\Users\yuzij\Documents\app\android\testdata\test_solder\*.jpg"))[:4]

m_pt = YOLO(PT)
m_onnx = YOLO(ONNX)

def grab(res, conf=0.05):
    out = []
    for b in res.boxes:
        out.append((int(b.cls.item()), float(b.conf.item()), *[float(v) for v in b.xyxy[0].tolist()]))
    return out

total = 0
maxconf = 0.0
maxbox = 0.0
mismatch = 0

for p in IMGS:
    r1 = m_pt.predict(p, imgsz=640, conf=0.05, verbose=False)[0]
    r2 = m_onnx.predict(p, imgsz=640, conf=0.05, verbose=False)[0]
    a, b = grab(r1), grab(r2)

    print(f"\n{os.path.basename(p)[:46]}  .pt={len(a)} 个  onnx={len(b)} 个")
    if len(a) != len(b):
        mismatch += 1
        print("   ⚠ 框数量不同")

    n = min(len(a), len(b))
    for i in range(n):
        dc = abs(a[i][1] - b[i][1])
        db = max(abs(a[i][2 + k] - b[i][2 + k]) for k in range(4))
        maxconf = max(maxconf, dc)
        maxbox = max(maxbox, db)
        total += 1
        print(f"   cls={a[i][0]}  conf .pt={a[i][1]:.6f}  onnx={b[i][1]:.6f}  "
              f"Δconf={dc:.2e}  Δbox={db:.2e}px")

print("\n==== 汇总 ====")
print(f"比较的框数: {total}   框数不一致的图片: {mismatch}")
print(f"最大置信度差: {maxconf:.3e}")
print(f"最大坐标差  : {maxbox:.3e} px")
print(f".pt 权重 dtype: {next(iter(m_pt.model.state_dict().values())).dtype}")