"""用同样的逐类阈值跑一遍本地验证图，作为 App 结果的基准。"""
import glob
import os

os.environ.setdefault("YOLO_CONFIG_DIR", r"C:\Users\yuzij\Documents\app\webapp\.ultralytics")
os.environ.setdefault("MPLBACKEND", "Agg")

import cv2
from ultralytics import YOLO

PT = r"C:\Users\yuzij\Documents\app\webapp\models\solder_yolo26m.pt"
IMG_DIR = r"C:\Users\yuzij\Documents\app\android\test_solder"
OUT = r"C:\Users\yuzij\Documents\app\android\test_solder_out"

CONF = {  # 模型卡给的逐类阈值
    "insufficient_solder": 0.297, "excess_solder": 0.349, "solder_bridge": 0.417,
    "solder_void": 0.249, "missing_component": 0.381, "shifted_component": 0.389,
    "burn": 0.224, "physical_damage": 0.214, "oxidation": 0.228,
}
names = list(CONF)

m = YOLO(PT)
os.makedirs(OUT, exist_ok=True)

for p in sorted(glob.glob(os.path.join(IMG_DIR, "*.jpg"))):
    # 用最低阈值 0.15 跑，再按逐类阈值过滤，等价于 App 里的做法
    res = m.predict(p, conf=0.15, imgsz=800, verbose=False)[0]
    keep = []
    for b in res.boxes:
        cid = int(b.cls.item())
        s = float(b.conf.item())
        if s >= CONF[names[cid]]:
            keep.append((names[cid], round(s, 3)))
    img = cv2.imread(p)
    print(f"{os.path.basename(p)[:52]:54s} {img.shape[1]}x{img.shape[0]}  保留 {len(keep)} 个")
    for n, s in keep:
        print(f"     {n:20s} {s}")
    if keep:
        cv2.imwrite(os.path.join(OUT, os.path.basename(p)), res.plot())