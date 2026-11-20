"""导出 ONNX 并带栈回溯诊断：卡住时能看到卡在哪个函数。"""
import faulthandler
import os
import sys
import time

os.environ.setdefault("YOLO_CONFIG_DIR", r"C:\Users\yuzij\Documents\app\webapp\.ultralytics")
os.environ.setdefault("MPLBACKEND", "Agg")

faulthandler.dump_traceback_later(45, repeat=True, file=sys.stderr)

from ultralytics import YOLO

print("[1] loading", flush=True)
m = YOLO(r"C:\Users\yuzij\Documents\app\webapp\models\best.pt")
print("[2] loaded; names:", m.names, flush=True)

t = time.perf_counter()
print("[3] exporting onnx ...", flush=True)
p = m.export(format="onnx", imgsz=640, simplify=False, opset=13,
             dynamic=False, batch=1, device="cpu")
print("[4] done ->", p, "%.1fs" % (time.perf_counter() - t), flush=True)