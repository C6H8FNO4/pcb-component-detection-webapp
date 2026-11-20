"""
把 800 的 ONNX 量化成 int8，并测量：体积 / 桌面延迟 / 在 val 集上的精度。

静态量化（QDQ，权重+激活都 int8），用 val 图做校准。
"""
import os
os.environ.setdefault("YOLO_CONFIG_DIR", r"C:\Users\yuzij\Documents\app\webapp\.ultralytics")
os.environ.setdefault("MPLBACKEND", "Agg")

import glob
import time
import numpy as np
import cv2

SRC = r"C:\Users\yuzij\Documents\app\webapp\models\solder_yolo26m_800.onnx"
DST = r"C:\Users\yuzij\Documents\app\webapp\models\solder_yolo26m_800_int8.onnx"
CAL_DIR = r"C:\Users\yuzij\Documents\app\android\solder_val\images\val"
DATA = r"C:\Users\yuzij\Documents\app\android\solder_val\data.yaml"
SIZE = 800
PAD = 114


def letterbox(path):
    img = cv2.imread(path)
    h, w = img.shape[:2]
    s = min(SIZE / w, SIZE / h)
    nw, nh = max(1, round(w * s)), max(1, round(h * s))
    resized = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
    canvas = np.full((SIZE, SIZE, 3), PAD, np.uint8)
    dx, dy = (SIZE - nw) // 2, (SIZE - nh) // 2
    canvas[dy:dy + nh, dx:dx + nw] = resized
    chw = canvas[:, :, ::-1].transpose(2, 0, 1)[None].astype(np.float32) / 255.0
    return np.ascontiguousarray(chw)


files = sorted(glob.glob(os.path.join(CAL_DIR, "*.jpg")))
print(f"校准图: {len(files)} 张", flush=True)

import onnx
m = onnx.load(SRC)
input_name = m.graph.input[0].name


class Reader:
    def __init__(self, paths):
        self.paths = paths
        self.i = 0

    def get_next(self):
        if self.i >= len(self.paths):
            return None
        p = self.paths[self.i]
        self.i += 1
        return {input_name: letterbox(p)}

    def rewind(self):
        self.i = 0


from onnxruntime.quantization import (quantize_static, QuantFormat, QuantType,
                                     CalibrationMethod)

t = time.perf_counter()
quantize_static(
    SRC, DST,
    Reader(files[:200]),
    quant_format=QuantFormat.QDQ,
    per_channel=True,
    activation_type=QuantType.QInt8,
    weight_type=QuantType.QInt8,
    calibrate_method=CalibrationMethod.MinMax,
)
print(f"量化完成 {time.perf_counter()-t:.1f}s  "
      f"{os.path.getsize(SRC)/1e6:.1f} MB → {os.path.getsize(DST)/1e6:.1f} MB", flush=True)

# ---- 桌面延迟对比 ----
import onnxruntime as ort
def bench(path, size=SIZE, n=5):
    so = ort.SessionOptions()
    so.intra_op_num_threads = 6
    so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
    sess = ort.InferenceSession(path, so, providers=["CPUExecutionProvider"])
    x = np.random.rand(1, 3, size, size).astype(np.float32)
    for _ in range(2):
        sess.run(None, {name: x} for name in [sess.get_inputs()[0].name])
    ts = []
    nm = sess.get_inputs()[0].name
    for _ in range(n):
        t0 = time.perf_counter()
        sess.run(None, {nm: x})
        ts.append((time.perf_counter() - t0) * 1000)
    return float(np.median(ts))

t_fp32 = bench(SRC)
t_int8 = bench(DST)
print(f"桌面延迟: fp32 {t_fp32:.0f} ms   int8 {t_int8:.0f} ms   提速 {t_fp32/t_int8:.2f}x", flush=True)

# ---- 精度验证 ----
from ultralytics import YOLO
print("\n=== 精度对比（687 张 val）===", flush=True)
for tag, path in (("fp32", SRC), ("int8", DST)):
    r = YOLO(path).val(data=DATA, imgsz=SIZE, split="val", verbose=False, plots=False)
    print(f"[{tag}] mAP50={r.box.map50:.4f}  mAP50-95={r.box.map:.4f}  "
          f"P={r.box.mp:.4f}  R={r.box.mr:.4f}", flush=True)