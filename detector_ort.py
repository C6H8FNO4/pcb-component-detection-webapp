"""
纯 onnxruntime 的 YOLO 推理（不依赖 torch / ultralytics）。

为什么不用 ultralytics：
    ultralytics 只是个封装，加载 .onnx 时底层仍是 onnxruntime，却强制依赖 torch
    （约 1.1 GB，且带 9 个原生 DLL）。在干净系统 / Windows Sandbox 上经常因为
    VC++ 运行库或 DLL 被拦截而无法启动。这里直接做 letterbox + 前向 + 解码 + NMS。

支持任何 YOLO 风格输出 (1, 4+nc, anchors) 的检测模型。
"""

from __future__ import annotations

import ast
import json
import os

import cv2
import numpy as np
import onnxruntime as ort

PAD_VALUE = 114


def read_onnx_meta(path: str) -> tuple[dict[int, str], int]:
    """从 ONNX 元数据读类别名与输入边长（不需要加载权重到内存）。"""
    names: dict[int, str] = {}
    size = 640
    try:
        import onnx
        m = onnx.load(path, load_external_data=False)
        props = {p.key: p.value for p in m.metadata_props}
        raw = props.get("names")
        if raw:
            try:
                obj = json.loads(raw)
            except Exception:
                obj = ast.literal_eval(raw)
            names = {int(k): str(v) for k, v in obj.items()}
        dims = m.graph.input[0].type.tensor_type.shape.dim
        if len(dims) >= 4 and dims[2].dim_value:
            size = int(dims[2].dim_value)
    except Exception:
        pass
    return names, size


class Result:
    __slots__ = ("boxes", "ms", "max_score", "size")

    def __init__(self):
        self.boxes: list[dict] = []
        self.ms: float = 0.0
        self.max_score: float = 0.0
        self.size: tuple[int, int] = (0, 0)


class Detector:
    """一个 ONNX 模型 + 逐类阈值。"""

    def __init__(self, model_path: str, per_class: dict | None = None,
                 global_conf: float = 0.25, threads: int | None = None):
        if not os.path.exists(model_path):
            raise FileNotFoundError(model_path)

        so = ort.SessionOptions()
        so.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_ALL
        if threads:
            so.intra_op_num_threads = max(1, int(threads))
        self.sess = ort.InferenceSession(model_path, so, providers=["CPUExecutionProvider"])
        self.input_name = self.sess.get_inputs()[0].name

        shape = self.sess.get_inputs()[0].shape
        self.size = int(shape[2]) if len(shape) >= 4 and isinstance(shape[2], int) else 640

        self.names, meta_size = read_onnx_meta(model_path)
        if not self.names:
            # 元数据缺失时退化成序号
            n_out = self.sess.get_outputs()[0].shape[1]
            self.names = {i: f"class_{i}" for i in range(int(n_out) - 4)}
        if meta_size:
            self.size = meta_size

        self.per_class = per_class or {}
        self.global_conf = float(global_conf)

    # ---------------------------------------------------------------- 推理
    def predict(self, img_bgr: np.ndarray, conf: float | None = None,
                iou: float = 0.45) -> Result:
        h, w = img_bgr.shape[:2]
        r = Result()
        r.size = (w, h)

        # 1) letterbox 到 size×size
        blob, scale, pad_x, pad_y = self._letterbox(img_bgr)

        # 2) 前向
        import time
        t0 = time.perf_counter()
        out = self.sess.run(None, {self.input_name: blob})[0]
        r.ms = (time.perf_counter() - t0) * 1000.0

        # 3) 解码 + 逐类 NMS
        pred = out[0] if out.ndim == 3 else out      # (4+nc, anchors)
        nc, anchors = pred.shape[0] - 4, pred.shape[1]
        cx, cy, bw, bh = pred[0], pred[1], pred[2], pred[3]

        cands = []
        for c in range(nc):
            scores = pred[4 + c]
            th = conf if conf is not None else self.per_class.get(
                self.names.get(c, ""), self.global_conf)
            if scores.size:
                r.max_score = max(r.max_score, float(scores.max()))
            idx = np.nonzero(scores >= th)[0]
            if idx.size == 0:
                continue
            x1 = (cx[idx] - bw[idx] / 2 - pad_x) / scale
            y1 = (cy[idx] - bh[idx] / 2 - pad_y) / scale
            x2 = (cx[idx] + bw[idx] / 2 - pad_x) / scale
            y2 = (cy[idx] + bh[idx] / 2 - pad_y) / scale
            for k, i in enumerate(idx):
                cands.append((float(scores[i]), c,
                              float(np.clip(x1[k], 0, w - 1)), float(np.clip(y1[k], 0, h - 1)),
                              float(np.clip(x2[k], 0, w - 1)), float(np.clip(y2[k], 0, h - 1))))

        if not cands:
            return r

        cands.sort(key=lambda t: -t[0])
        if len(cands) > 1000:
            cands = cands[:1000]

        kept: list[tuple] = []
        for cand in cands:
            ok = True
            for k in kept:
                if k[1] != cand[1]:
                    continue
                if self._iou(k, cand) > iou:
                    ok = False
                    break
            if ok:
                kept.append(cand)

        for s, c, x1, y1, x2, y2 in kept:
            if x2 - x1 < 1 or y2 - y1 < 1:
                continue
            name = self.names.get(c, str(c))
            r.boxes.append({
                "cls": c, "name": name, "conf": round(s, 4),
                "xyxy": [round(x1, 1), round(y1, 1), round(x2, 1), round(y2, 1)],
            })
        r.boxes.sort(key=lambda d: -d["conf"])
        return r

    # ---------------------------------------------------------------- 工具
    def _letterbox(self, img: np.ndarray):
        s = self.size
        h, w = img.shape[:2]
        scale = min(s / w, s / h)
        nw, nh = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
        resized = cv2.resize(img, (nw, nh), interpolation=cv2.INTER_LINEAR)
        canvas = np.full((s, s, 3), PAD_VALUE, np.uint8)
        pad_x, pad_y = (s - nw) // 2, (s - nh) // 2
        canvas[pad_y:pad_y + nh, pad_x:pad_x + nw] = resized
        # BGR → RGB, HWC → CHW, /255
        blob = canvas[:, :, ::-1].transpose(2, 0, 1)[None].astype(np.float32) / 255.0
        return np.ascontiguousarray(blob), scale, pad_x, pad_y

    @staticmethod
    def _iou(a, b) -> float:
        ax1, ay1, ax2, ay2 = a[2], a[3], a[4], a[5]
        bx1, by1, bx2, by2 = b[2], b[3], b[4], b[5]
        ix = max(0.0, min(ax2, bx2) - max(ax1, bx1))
        iy = max(0.0, min(ay2, by2) - max(ay1, by1))
        inter = ix * iy
        if inter <= 0:
            return 0.0
        ua = (ax2 - ax1) * (ay2 - ay1) + (bx2 - bx1) * (by2 - by1) - inter
        return inter / ua if ua > 0 else 0.0