"""
PCB 缺陷检测 Web 界面（Gradio 版，最简单，几十行起一个网页）

启动：
    python app_gradio.py
然后在浏览器打开 http://127.0.0.1:7860

依赖：ultralytics, gradio, opencv-python, pandas
"""

from __future__ import annotations

import os
import tempfile

import cv2
import gradio as gr
import pandas as pd
from ultralytics import YOLO

# ---------------------------------------------------------------- 配置
# 权重路径：优先读环境变量 PCB_WEIGHTS，否则用下面的默认值（改成你的实际路径）
WEIGHTS = os.environ.get(
    "PCB_WEIGHTS",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..",
                 "pcb_defect_yolo26n_zip", "pcb_defect_yolo26n", "weights", "best.pt"),
)
WEIGHTS = os.path.abspath(WEIGHTS)

CN = {
    "missing_hole": "缺孔",
    "mouse_bite": "鼠咬",
    "open_circuit": "开路",
    "short": "短路",
    "spur": "毛刺",
    "spurious_copper": "余铜",
}

model = YOLO(WEIGHTS)
print(f"[PCB] 已加载模型: {WEIGHTS}")
print(f"[PCB] 类别: {model.names}")


def detect(image_rgb, conf, iou, imgsz):
    """image_rgb: Gradio 给的 HWC RGB uint8；ultralytics 需要 BGR。"""
    if image_rgb is None:
        return None, pd.DataFrame(), "请先上传一张 PCB 图片", None

    bgr = cv2.cvtColor(image_rgb, cv2.COLOR_RGB2BGR)
    res = model.predict(bgr, conf=float(conf), iou=float(iou),
                        imgsz=int(imgsz), verbose=False)[0]

    rows = []
    for i, box in enumerate(res.boxes or []):
        cid = int(box.cls.item())
        x1, y1, x2, y2 = [round(v, 1) for v in box.xyxy[0].tolist()]
        rows.append({
            "序号": i + 1,
            "类别": model.names[cid],
            "中文": CN.get(model.names[cid], ""),
            "置信度": round(float(box.conf.item()), 4),
            "x1": x1, "y1": y1, "x2": x2, "y2": y2,
            "宽": round(x2 - x1, 1),
            "高": round(y2 - y1, 1),
            "面积px": int((x2 - x1) * (y2 - y1)),
        })

    df = pd.DataFrame(rows, columns=["序号", "类别", "中文", "置信度",
                                     "x1", "y1", "x2", "y2", "宽", "高", "面积px"])

    annotated = cv2.cvtColor(res.plot(), cv2.COLOR_BGR2RGB)

    if rows:
        cnt = df["类别"].value_counts()
        lines = [f"共检测到 {len(rows)} 个缺陷："]
        for name, n in cnt.items():
            lines.append(f"  · {name}（{CN.get(name, '')}）：{n} 个")
        summary = "\n".join(lines)
        worst = df.loc[df["置信度"].idxmin()]
        summary += f"\n最低置信度样本：{worst['类别']} @ {worst['置信度']}"
    else:
        summary = "未检测到缺陷。（若确实有缺陷，可把置信度阈值降到 0.15 再试）"

    csv_path = os.path.join(tempfile.gettempdir(), "pcb_detections.csv")
    df.to_csv(csv_path, index=False, encoding="utf-8-sig")

    return annotated, df, summary, csv_path


with gr.Blocks(title="PCB 缺陷检测") as demo:
    gr.Markdown(
        "## PCB 缺陷检测\n"
        "模型：YOLO26n · 6 类缺陷（缺孔 / 鼠咬 / 开路 / 短路 / 毛刺 / 余铜）\n\n"
        "上传图片 → 自动标注 → 可下载标注图与检测明细 CSV。"
    )

    with gr.Row():
        with gr.Column(scale=1):
            img_in = gr.Image(label="上传 PCB 图片", type="numpy", height=320)
            with gr.Accordion("检测参数", open=False):
                conf = gr.Slider(0.05, 0.95, value=0.25, step=0.05,
                                 label="置信度阈值 conf")
                iou = gr.Slider(0.1, 0.9, value=0.70, step=0.05,
                                label="NMS IoU 阈值")
                imgsz = gr.Dropdown([640, 960, 1280], value=640,
                                    label="推理尺寸 imgsz（训练为 640）")
            btn = gr.Button("开始检测", variant="primary")

        with gr.Column(scale=1):
            img_out = gr.Image(label="检测结果", type="numpy", height=320)
            txt = gr.Textbox(label="汇总", lines=6)
            table = gr.Dataframe(label="检测明细", wrap=True)
            csv = gr.File(label="下载检测明细 CSV")

    btn.click(detect, inputs=[img_in, conf, iou, imgsz],
              outputs=[img_out, table, txt, csv], api_name="detect")
    img_in.upload(detect, inputs=[img_in, conf, iou, imgsz],
                  outputs=[img_out, table, txt, csv])


if __name__ == "__main__":
    demo.launch(server_name="127.0.0.1", server_port=7860, show_api=False)