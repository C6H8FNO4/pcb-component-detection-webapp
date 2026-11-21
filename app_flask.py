"""
PCB 缺陷检测本地网页服务（多模型版）

启动：
    python app_flask.py
浏览器打开 http://127.0.0.1:8000

模型来自同目录的 models/ 文件夹，启动时自动扫描 *.onnx：
  · solder_yolo26m_800.onnx  → 键名 solder  （焊接/装配缺陷，9 类，imgsz 800）
  · best.onnx                → 键名 bare    （裸板缺陷，6 类，imgsz 640）
  · 文件名以 _640/_320 结尾的视为备用导出，默认不列出

接口：
  GET  /api/models
       [{key,label,imgsz,classes:[{index,name,cn,conf}],has_per_class_conf}, ...]

  POST /api/predict   multipart/form-data
       file=<图片>  model=solder|bare   [conf=0.25]  [iou=0.45]
       conf 不传则用逐类推荐阈值；传了就用统一阈值覆盖
       返回 { ok, count, image, detections[], summary, model, ms }
"""

from __future__ import annotations

import base64
import json
import os
import sys
import threading
import time
from collections import OrderedDict
from pathlib import Path

import cv2
import numpy as np
from flask import Flask, jsonify, render_template, request

# 便携包用的是 python-embed（带 ._pth），该模式下脚本目录不会自动进 sys.path，
# 显式加入以保证能 import detector_ort（对普通解释器无副作用）。
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)
from detector_ort import Detector

BASE_DIR = Path(__file__).resolve().parent
MODEL_DIR = Path(os.environ.get("PCB_MODEL_DIR", BASE_DIR / "models"))
CONF_FILE = MODEL_DIR / "models.json"

CN = {
    # 焊接/装配（9 类）
    "insufficient_solder": "少锡", "excess_solder": "多锡", "solder_bridge": "连锡",
    "solder_void": "空洞", "missing_component": "缺件", "shifted_component": "偏移",
    "burn": "烧焦", "physical_damage": "损伤", "oxidation": "氧化",
    # 裸板（7 类）
    "missing_hole": "缺孔", "mouse_bite": "鼠咬", "open_circuit": "开路",
    "short": "短路", "spur": "毛刺", "spurious_copper": "余铜", "pin_hole": "针孔",
}

COLORS = [
    (82, 82, 255), (0, 179, 255), (255, 196, 64), (129, 64, 255), (255, 77, 124),
    (118, 230, 0), (64, 110, 255), (251, 64, 224), (255, 255, 24),
]

# 默认逐类阈值（来自 solder 模型卡）；可用 models.json 覆盖
DEFAULT_PER_CLASS = {
    "insufficient_solder": 0.297, "excess_solder": 0.349, "solder_bridge": 0.417,
    "solder_void": 0.249, "missing_component": 0.381, "shifted_component": 0.389,
    "burn": 0.224, "physical_damage": 0.214, "oxidation": 0.228,
}

# 文件名 → 展示名（未列出的按文件名自动起名）
LABELS = {
    "solder": "焊接 / 装配缺陷（YOLO26m · 9 类）",
    "bare": "裸板缺陷（YOLO26n · 6 类）",
}

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 32 * 1024 * 1024

_lock = threading.Lock()
_cache: "OrderedDict[str, ModelEntry]" = OrderedDict()
MAX_LOADED = 2          # 同时常驻的模型数量（每个 80 MB 级，别开太大）


# --------------------------------------------------------------------------- 模型发现

def _stem_to_key(stem: str) -> str:
    s = stem.lower()
    if s.startswith("solder"):
        return "solder"
    if s in ("best", "bare") or s.startswith("bare"):
        return "bare"
    return s


def _parse_names(raw: str) -> dict[int, str]:
    """ultralytics 把 names 写成 Python dict 的字符串形式，不是 JSON。"""
    import ast
    try:
        obj = json.loads(raw)
    except Exception:
        obj = ast.literal_eval(raw)
    return {int(k): str(v) for k, v in obj.items()}


def _read_onnx_meta(path: Path) -> tuple[dict[int, str], int]:
    """从 ONNX 元数据里读类别名和输入尺寸，避免为了列表去加载整个模型。"""
    names: dict[int, str] = {}
    imgsz = 640
    try:
        import onnx
        m = onnx.load(str(path), load_external_data=False)
        props = {p.key: p.value for p in m.metadata_props}
        if props.get("names"):
            names = _parse_names(props["names"])
        dims = m.graph.input[0].type.tensor_type.shape.dim
        if len(dims) >= 4 and dims[2].dim_value:
            imgsz = int(dims[2].dim_value)
        elif props.get("imgsz"):
            imgsz = int(json.loads(props["imgsz"]))
    except Exception as e:
        print(f"[PCB] 读取 {path.name} 元数据失败: {e}")
    return names, imgsz


def _load_conf_overrides() -> dict:
    if CONF_FILE.exists():
        try:
            return json.loads(CONF_FILE.read_text(encoding="utf-8"))
        except Exception as e:
            print(f"[PCB] models.json 解析失败: {e}")
    return {}


def discover_models() -> dict[str, dict]:
    """扫描 models/*.onnx，返回 {key: 描述}。"""
    overrides = _load_conf_overrides()
    found: dict[str, dict] = {}

    for p in sorted(MODEL_DIR.glob("*.onnx")):
        stem = p.stem
        if stem.endswith("_640") or stem.endswith("_320") or stem.endswith("_int8"):
            continue                      # 备用导出，不列出
        key = _stem_to_key(stem)
        if key in found:
            continue
        names, imgsz = _read_onnx_meta(p)
        ov = overrides.get(key, {})
        per_class = ov.get("per_class", None)
        if per_class is None and all(n in DEFAULT_PER_CLASS for n in names.values()):
            per_class = DEFAULT_PER_CLASS
        found[key] = {
            "key": key,
            "file": p.name,
            "path": str(p),
            "label": ov.get("label") or LABELS.get(key, stem),
            "imgsz": imgsz,
            "names": names,
            "per_class": per_class,
            "global_conf": ov.get("global", 0.25),
        }
    return found


class ModelEntry:
    """懒加载的模型句柄：真正用到才加载，并在内存里复用。

    用 pure onnxruntime 推理（detector_ort.Detector），不依赖 torch / ultralytics：
    包体积从 ~1.2 GB 降到 ~150 MB，也不再需要 VC++ 运行库以外的原生依赖。
    """

    def __init__(self, desc: dict):
        self.desc = desc
        self.key = desc["key"]
        self.model = Detector(
            desc["path"],
            per_class=desc.get("per_class"),
            global_conf=desc.get("global_conf", 0.25),
        )
        self.lock = threading.Lock()

    @property
    def names(self) -> dict[int, str]:
        return self.model.names

    def predict(self, img, conf: float | None, iou: float, imgsz: int):
        """返回 detector_ort.Result；imgsz 由模型自身决定（ONNX 输入固定）。"""
        with self.lock:
            return self.model.predict(img, conf=conf, iou=iou)


def get_model(key: str) -> ModelEntry:
    desc = MODELS.get(key)
    if desc is None:
        raise KeyError(key)
    with _lock:
        ent = _cache.get(key)
        if ent is not None:
            _cache.move_to_end(key)
            return ent
        ent = ModelEntry(desc)
        _cache[key] = ent
        while len(_cache) > MAX_LOADED:
            old_key, _ = _cache.popitem(last=False)
            print(f"[PCB] 卸载模型 {old_key}（保持常驻 {MAX_LOADED} 个）")
        print(f"[PCB] 已加载模型 {key} ← {desc['file']}")
        return ent


# --------------------------------------------------------------------------- 画框

def draw_boxes(img, dets: list[dict]) -> np.ndarray:
    out = img.copy()
    h, w = out.shape[:2]
    scale = max(w, h) / 640.0
    thick = max(2, int(round(3 * scale)))
    font_scale = max(0.5, 0.55 * scale)

    for d in dets:
        c = COLORS[d["cls"] % len(COLORS)]
        x1, y1, x2, y2 = [int(round(v)) for v in d["xyxy"]]
        cv2.rectangle(out, (x1, y1), (x2, y2), c, thick)
        text = f'{d["name"]} {d["conf"]:.2f}'
        (tw, th), base = cv2.getTextSize(text, cv2.FONT_HERSHEY_SIMPLEX, font_scale, max(1, thick // 2))
        ty = y1 - th - base - 2
        if ty < 0:
            ty = y2 + 2
        cv2.rectangle(out, (x1, ty), (x1 + tw + 4, ty + th + base + 2), c, -1)
        cv2.putText(out, text, (x1 + 2, ty + th + 1), cv2.FONT_HERSHEY_SIMPLEX,
                    font_scale, (20, 20, 20), max(1, thick // 2), cv2.LINE_AA)
    return out


# --------------------------------------------------------------------------- 路由

MODELS: dict[str, dict] = {}
try:
    MODELS = discover_models()
    for k, v in MODELS.items():
        print(f"[PCB] 发现模型 {k}: {v['file']}  imgsz={v['imgsz']}  {len(v['names'])} 类")
except Exception as e:
    print(f"[PCB] 模型扫描失败: {e}")


def _preload():
    """后台预热：避免用户第一次点检测时干等模型加载（solder 约 8–12 秒）。"""
    if os.environ.get("PCB_PRELOAD", "1") != "1":
        return
    for k in list(MODELS):
        try:
            t = time.perf_counter()
            get_model(k)
            print(f"[PCB] 预热完成 {k} ({time.perf_counter()-t:.1f}s)")
        except Exception as e:
            print(f"[PCB] 预热失败 {k}: {e}")


threading.Thread(target=_preload, daemon=True).start()


def _models_payload():
    out = []
    for k, v in MODELS.items():
        per = v.get("per_class") or {}
        out.append({
            "key": k,
            "label": v["label"],
            "file": v["file"],
            "imgsz": v["imgsz"],
            "has_per_class_conf": bool(per),
            "global_conf": v["global_conf"],
            "classes": [
                {"index": i, "name": n, "cn": CN.get(n, ""),
                 "conf": per.get(n, v["global_conf"])}
                for i, n in sorted(v["names"].items())
            ],
        })
    return out


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/api/models")
def api_models():
    return jsonify(ok=True, models=_models_payload())


@app.post("/api/predict")
def api_predict():
    f = request.files.get("file")
    if f is None or not f.filename:
        return jsonify(ok=False, error="没有收到文件字段 file"), 400

    key = request.form.get("model") or next(iter(MODELS), None)
    if not key or key not in MODELS:
        return jsonify(ok=False, error=f"未知模型: {key}",
                       available=list(MODELS)), 400

    buf = np.frombuffer(f.read(), dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if img is None:
        return jsonify(ok=False, error="图片解码失败，请换 jpg/png"), 400

    iou = float(request.form.get("iou", 0.45))
    conf_raw = request.form.get("conf")
    conf = float(conf_raw) if conf_raw not in (None, "", "null") else None

    desc = MODELS[key]
    per_class = desc.get("per_class") or {}
    ent = get_model(key)
    imgsz = desc["imgsz"]

    t0 = time.perf_counter()
    res = ent.predict(img, conf, iou, imgsz)
    ms = (time.perf_counter() - t0) * 1000

    dets = []
    for box in res.boxes or []:
        cid = int(box.cls.item())
        name = ent.names.get(cid, str(cid))
        sc = float(box.conf.item())
        # 逐类阈值过滤（conf 显式传入时以它为准）
        if conf is None and per_class and sc < per_class.get(name, desc["global_conf"]):
            continue
        x1, y1, x2, y2 = [round(v, 1) for v in box.xyxy[0].tolist()]
        dets.append({
            "cls": cid, "name": name, "cn": CN.get(name, ""),
            "conf": round(sc, 4),
            "xyxy": [x1, y1, x2, y2],
            "w": round(x2 - x1, 1), "h": round(y2 - y1, 1),
        })

    ok, enc = cv2.imencode(".jpg", draw_boxes(img, dets),
                           [int(cv2.IMWRITE_JPEG_QUALITY), 90])
    data_url = "data:image/jpeg;base64," + base64.b64encode(enc.tobytes()).decode()

    if dets:
        counts: dict[str, int] = {}
        for d in dets:
            counts[d["name"]] = counts.get(d["name"], 0) + 1
        summary = f"共 {len(dets)} 个缺陷：" + "，".join(
            f"{k}({CN.get(k, '')})×{v}" for k, v in counts.items())
    else:
        summary = "未检测到缺陷"

    return jsonify(ok=True, model=key, model_label=desc["label"],
                   count=len(dets), image=data_url, detections=dets,
                   summary=summary, ms=round(ms, 1),
                   size={"w": img.shape[1], "h": img.shape[0]})


@app.post("/api/detect")
def api_detect():
    """轻量版：只返回检测结果，不回传图片（前端自己在 canvas 上画框）。

    实时模式专用 —— 省掉服务端 JPEG 编码 + 客户端解码，往返快很多。
    """
    f = request.files.get("file")
    if f is None:
        return jsonify(ok=False, error="没有收到文件字段 file"), 400

    key = request.form.get("model") or next(iter(MODELS), None)
    if not key or key not in MODELS:
        return jsonify(ok=False, error=f"未知模型: {key}", available=list(MODELS)), 400

    buf = np.frombuffer(f.read(), dtype=np.uint8)
    img = cv2.imdecode(buf, cv2.IMREAD_COLOR)
    if img is None:
        return jsonify(ok=False, error="图片解码失败"), 400

    iou = float(request.form.get("iou", 0.45))
    conf_raw = request.form.get("conf")
    conf = float(conf_raw) if conf_raw not in (None, "", "null") else None

    desc = MODELS[key]
    per_class = desc.get("per_class") or {}
    ent = get_model(key)

    t0 = time.perf_counter()
    res = ent.predict(img, conf, iou, desc["imgsz"])
    ms = (time.perf_counter() - t0) * 1000

    dets = []
    for box in res.boxes or []:
        cid = int(box.cls.item())
        name = ent.names.get(cid, str(cid))
        sc = float(box.conf.item())
        if conf is None and per_class and sc < per_class.get(name, desc["global_conf"]):
            continue
        x1, y1, x2, y2 = [round(v, 1) for v in box.xyxy[0].tolist()]
        dets.append({"cls": cid, "name": name, "cn": CN.get(name, ""),
                     "conf": round(sc, 3), "xyxy": [x1, y1, x2, y2]})

    return jsonify(ok=True, model=key, count=len(dets), detections=dets,
                   ms=round(ms, 1), size={"w": img.shape[1], "h": img.shape[0]})


def _lan_ip() -> str | None:
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return None
    finally:
        s.close()


if __name__ == "__main__":
    HOST = os.environ.get("PCB_HOST", "0.0.0.0")
    PORT = int(os.environ.get("PCB_PORT", "8000"))
    print(f"[PCB] 监听 {HOST}:{PORT}")
    print(f"[PCB] 本机访问:   http://127.0.0.1:{PORT}/")
    ip = _lan_ip()
    if ip and HOST == "0.0.0.0":
        print(f"[PCB] 局域网访问: http://{ip}:{PORT}/   (需防火墙放行 {PORT})")
    app.run(host=HOST, port=PORT, debug=False, threaded=True)