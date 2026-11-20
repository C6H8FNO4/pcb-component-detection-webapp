"""导出 solder 模型 ONNX（800 / 640 两版）并用 onnxruntime 实测 CPU 速度。"""
import os
import time

import numpy as np

os.environ.setdefault("YOLO_CONFIG_DIR", r"C:\Users\yuzij\Documents\app\webapp\.ultralytics")
os.environ.setdefault("MPLBACKEND", "Agg")

SRC = r"C:\Users\yuzij\Documents\app\webapp\models\solder_yolo26m.pt"
OUT_DIR = r"C:\Users\yuzij\Documents\app\webapp\models"
os.makedirs(OUT_DIR, exist_ok=True)

from ultralytics import YOLO

m = YOLO(SRC)
print("names:", m.names, flush=True)

paths = {}
for size in (800, 640):
    p = os.path.join(OUT_DIR, f"solder_yolo26m_{size}.onnx")
    if not os.path.exists(p):
        t = time.perf_counter()
        m.export(format="onnx", imgsz=size, opset=13, simplify=False, dynamic=False)
        # ultralytics 导到源文件旁边，搬过来
        exported = os.path.splitext(SRC)[0] + ".onnx"
        if os.path.exists(exported):
            os.replace(exported, p)
        print(f"export {size}: {time.perf_counter()-t:.1f}s", flush=True)
    paths[size] = p
    print(f"{size}: {os.path.getsize(p)/1e6:.1f} MB", flush=True)

# ---- onnxruntime 基准 ----
import onnxruntime as ort

for size, p in paths.items():
    so = ort.SessionOptions()
    so.intra_op_num_threads = 6
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    sess = ort.InferenceSession(p, so, providers=["CPUExecutionProvider"])
    name = sess.get_inputs()[0].name
    x = np.random.rand(1, 3, size, size).astype(np.float32)
    for _ in range(2):
        sess.run(None, {name: x})
    ts = []
    for _ in range(5):
        t = time.perf_counter()
        out = sess.run(None, {name: x})
        ts.append((time.perf_counter() - t) * 1000)
    o = out[0]
    print(f"[{size}] output {o.shape}  median {np.median(ts):.0f} ms  (min {min(ts):.0f} / max {max(ts):.0f})",
          flush=True)