"""
单图 / 整目录 批量推理脚本（不启服务，纯批处理）

用法：
    python infer_cli.py 图片.jpg
    python infer_cli.py 图片目录/ --conf 0.2 --out result/
    python infer_cli.py 图片.jpg --json        # 只输出 JSON，便于被别的程序调用

输出：每张图同目录（或 --out）生成 <原名>_pred.jpg 和 <原名>.json
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

import cv2
from ultralytics import YOLO

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_W = os.path.join(HERE, "..", "pcb_defect_yolo26n_zip",
                         "pcb_defect_yolo26n", "weights", "best.pt")

CN = {"missing_hole": "缺孔", "mouse_bite": "鼠咬", "open_circuit": "开路",
      "short": "短路", "spur": "毛刺", "spurious_copper": "余铜"}
EXTS = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff"}


def collect(src):
    if os.path.isfile(src):
        return [src]
    out = []
    for root, _, files in os.walk(src):
        for f in files:
            if os.path.splitext(f)[1].lower() in EXTS:
                out.append(os.path.join(root, f))
    return sorted(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source", help="图片路径或目录")
    ap.add_argument("--weights", default=os.environ.get("PCB_WEIGHTS", DEFAULT_W))
    ap.add_argument("--conf", type=float, default=0.25)
    ap.add_argument("--iou", type=float, default=0.7)
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--device", default=None, help="0 / cpu")
    ap.add_argument("--out", default=None, help="结果输出目录，默认与源图同目录")
    ap.add_argument("--json", action="store_true", help="只打印 JSON；画图与文件都不写")
    a = ap.parse_args()

    files = collect(a.source)
    if not files:
        sys.exit(f"没找到图片: {a.source}")

    model = YOLO(os.path.abspath(a.weights))
    if a.out:
        os.makedirs(a.out, exist_ok=True)

    all_results = []
    t_all = time.perf_counter()

    for path in files:
        img = cv2.imread(path)
        if img is None:
            print(f"[skip] 读不了: {path}", file=sys.stderr)
            continue
        t0 = time.perf_counter()
        res = model.predict(img, conf=a.conf, iou=a.iou,
                            imgsz=a.imgsz, device=a.device, verbose=False)[0]
        dt = (time.perf_counter() - t0) * 1000

        dets = []
        for box in res.boxes or []:
            cid = int(box.cls.item())
            x1, y1, x2, y2 = [round(v, 1) for v in box.xyxy[0].tolist()]
            name = model.names[cid]
            dets.append({"cls": cid, "name": name, "cn": CN.get(name, ""),
                         "conf": round(float(box.conf.item()), 4),
                         "xyxy": [x1, y1, x2, y2]})

        item = {"file": path, "w": img.shape[1], "h": img.shape[0],
                "ms": round(dt, 1), "count": len(dets), "detections": dets}
        all_results.append(item)

        if not a.json:
            stem = os.path.splitext(os.path.basename(path))[0]
            outdir = a.out or os.path.dirname(os.path.abspath(path))
            cv2.imwrite(os.path.join(outdir, f"{stem}_pred.jpg"), res.plot())
            with open(os.path.join(outdir, f"{stem}.json"), "w", encoding="utf-8") as f:
                json.dump(item, f, ensure_ascii=False, indent=2)
            print(f"{os.path.basename(path)}: {len(dets)} 个缺陷, {dt:.1f} ms")

    total = (time.perf_counter() - t_all) * 1000
    if a.json:
        print(json.dumps({"files": all_results,
                          "total_ms": round(total, 1)}, ensure_ascii=False, indent=2))
    else:
        print(f"\n完成 {len(all_results)} 张，总耗时 {total/1000:.2f} s，"
              f"平均 {total/max(1,len(all_results)):.1f} ms/张")


if __name__ == "__main__":
    main()