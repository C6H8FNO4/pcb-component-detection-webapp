"""在 val 集上比较 800 / 640 两种推理尺寸的精度，为“降分辨率换速度”提供依据。"""
import os

os.environ.setdefault("YOLO_CONFIG_DIR", r"C:\Users\yuzij\Documents\app\webapp\.ultralytics")
os.environ.setdefault("MPLBACKEND", "Agg")

from ultralytics import YOLO

PT = r"C:\Users\yuzij\Documents\app\webapp\models\solder_yolo26m.pt"
DATA = r"C:\Users\yuzij\Documents\app\android\solder_val\data.yaml"

m = YOLO(PT)
for size in (800, 640):
    r = m.val(data=DATA, imgsz=size, split="val", verbose=False, plots=False, save_json=False)
    print(f"[imgsz={size}] mAP50={r.box.map50:.4f}  mAP50-95={r.box.map:.4f}  "
          f"P={r.box.mp:.4f}  R={r.box.mr:.4f}", flush=True)
    maps = r.box.maps
    if maps is not None:
        names = m.names
        per = "  ".join(f"{names[i][:12]}={maps[i]:.3f}" for i in range(len(maps)))
        print(f"    per-class: {per}", flush=True)