# 模型说明

**本目录不存 ONNX 权重**（体积大、且超过 GitHub 单文件 100 MB 限制）。
推理模型统一托管在独立仓库的 Release：

> https://github.com/C6H8FNO4/pcb-component-detection-models/releases

## 取模型

```bash
python tools/fetch_models.py          # 缺什么下什么
python tools/fetch_models.py --force  # 全部重下
python tools/fetch_models.py --list   # 看清单和下载地址
```

`install-gpu.ps1` / `install-gpu.sh` / `tools/make_portable.ps1` 都会自动调用这个脚本。

## 模型清单

| 文件名（放到本目录） | 键名 | 类别 | imgsz | 精度 | 体积 |
|---|---|---|---|---|---|
| `solder_yolo26m_800.onnx` | `solder` | 焊接/装配缺陷 9 类 | 800 | fp32 | 81.8 MB |
| `bare_yolo26s_1024.onnx` | `bare` | 裸板缺陷 7 类 | 1024 | fp32 | 38.4 MB |
| `seg_yolov8m_pcb.onnx` | `seg` | PCB 缺陷分割 4 类 | 640 | fp32 | 109.1 MB |

类别阈值在 `models.json` 里，随仓库提交。

## 注册表规则（`app_flask.py` 的 `discover_models()`）

- 扫描本目录的 `*.onnx`
- 文件名以 `_640` / `_320` / `_int8` 结尾的视为备用导出，不列出
- 类别名与输入尺寸从 ONNX 元数据读取，不用手工维护
- 键名：`solder*` → `solder`，`bare*`/`best` → `bare`，`seg*` → `seg`，其余用文件名
- 展示名与阈值来自 `models.json`

## 加第四个模型

1. 把 ONNX 传到 [models 仓库](https://github.com/C6H8FNO4/pcb-component-detection-models) 的 Release
2. 在 `tools/fetch_models.py` 的 `MODELS` 列表里加一行
3. 在 `models.json` 里加一段 `label` / `global` / `per_class`

前端下拉框会自动出现，不用改前端代码。

## 源权重

原始 `.pt` 在同名模型仓库的仓库文件里（`solder/`、`bare/`、`seg/`），
需要重新导出时用：

```python
from ultralytics import YOLO
YOLO("seg/converted-best.pt").export(format="onnx", imgsz=640, opset=13, half=False)
```