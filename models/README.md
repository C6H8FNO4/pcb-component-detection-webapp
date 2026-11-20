# 把模型权重放到这个目录

仓库**不包含**模型权重（体积原因）。需要自己下载并导出：

| 键名 | 文件名（必须一致） | 来源 | 导出参数 |
|---|---|---|---|
| `solder` | `solder_yolo26m_800.onnx` | [ParsaVictor/pcb-solder-defect-detection-yolo26](https://huggingface.co/ParsaVictor/pcb-solder-defect-detection-yolo26) 的 `best.pt` | `imgsz=800` |
| `bare` | `bare_yolo26s_1024.onnx` | [ParsaVictor/pcb-bare-board-defect-detection-yolo26](https://huggingface.co/ParsaVictor/pcb-bare-board-defect-detection-yolo26) 的 `best.pt` | `imgsz=1024` |

导出命令（在装了 ultralytics 的环境里）：

```python
from ultralytics import YOLO
YOLO("best.pt").export(format="onnx", imgsz=800, opset=13, simplify=False)
# 裸板模型把 imgsz 改成 1024
```

然后把导出的 `best.onnx` 重命名成上表对应的文件名，放到本目录。

## 注册表规则（`app_flask.py` 的 `discover_models()`）

- 扫描本目录下的 `*.onnx`
- 文件名以 `_640` / `_320` / `_int8` 结尾的视为备用导出，不列出
- 类名和输入尺寸直接从 ONNX 元数据读取（`names` / 输入 shape），不用手工填
- 键名规则：`solder*` → `solder`，`bare*` 或 `best` → `bare`，其余用文件名
- 展示名和阈值来自 `models.json`；没有配置时用默认阈值

## 加第三个模型？

把 ONNX 放进来，在 `models.json` 里加一段（`label` / `global` / `per_class`）即可，
前端下拉框会自动出现，不用改代码。`pcb-component-detection-yolo26` 就是这样一个待接入的模型。