# PCB 缺陷检测 · Web 服务

本地运行的 PCB 缺陷检测网页：浏览器上传图片或抓取实时画面 → 自动标注 → 出明细表 / CSV。
推理在本机 CPU（或 GPU）上跑，不依赖任何云服务。

支持两个模型，页面右上角切换：

| 键名 | 模型 | 类别数 | imgsz |
|---|---|---|---|
| `solder` | YOLO26m 焊接/装配缺陷 | 9 | 800 |
| `bare` | YOLO26s 裸板缺陷 | 7 | 1024 |

---

## 快速开始

### 方式一：便携包（零安装）

从 [Releases](https://github.com/C6H8FNO4/pcb-component-detection-webapp/releases) 下载
`pcb-webapp-portable-win64.zip`（约 442 MB），解压后双击 `启动.bat`。

- 内含便携 Python 3.10 + 全部依赖 + 两个模型
- 不需要装 Python、不需要联网
- Windows 10/11 x64

### 方式二：脚本安装（可选 GPU）

```powershell
.\install-gpu.ps1          # 菜单：CPU / CUDA 12.1 / 12.4 / 12.6 / 12.8
```

脚本会探测显卡与驱动（`nvidia-smi`）、按驱动版本推荐 CUDA、建虚拟环境、装对应 torch、
失败自动切清华镜像、自检 `torch.cuda.is_available()`，最后检查模型并启动。

```powershell
.\install-gpu.ps1 -Backend cu124            # 跳过菜单
.\install-gpu.ps1 -Backend cpu -Mirror      # CPU + 国内镜像
.\install-gpu.ps1 -Backend cpu -SkipDeps    # 环境已就绪，只做检查
```

Linux / macOS：`bash install-gpu.sh`（同样的参数）。

### 方式三：手动

```powershell
python -m venv .venv
.venv\Scripts\activate
pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
pip install -r requirements.txt
.venv\Scripts\python.exe app_flask.py
```

打开 <http://127.0.0.1:8000>。Windows 上也可以直接双击 `start.bat`。

---

## 界面功能

### 单张检测

拖拽或选择图片 → 标注图 + 类别计数 + 每个框的类别/置信度/像素坐标 → 可导出 CSV。
「按类别推荐阈值」勾选时使用每个类别的模型卡阈值，取消后可手动拖统一阈值。

### 实时检测

两种画面来源：

- **摄像头**：`getUserMedia`
- **抓取窗口 / 屏幕**：`getDisplayMedia` —— 适合把显微镜软件、相机软件、产线画面的窗口直接丢进来检测

显示与推理解耦：每帧立即显示并叠加「上一次的检测结果」，推理在独立请求里跑，
上一帧没算完就跳过采集，不排队。HUD 显示 `检测帧率 / 单帧推理耗时 / 帧尺寸 / 缺陷数`。

还带一个 **自测** 按钮：用合成画面跑完整链路，不需要摄像头，用来验证服务是否正常。

> ⚠️ 摄像头与屏幕抓取需要**安全上下文**：`http://127.0.0.1` 可以，
> 通过局域网 IP 用 `http://` 访问会被浏览器拒绝（需 https）。单张检测不受此限制。

---

## API

| 接口 | 说明 |
|---|---|
| `GET /api/models` | 列出可用模型、类别、阈值、imgsz |
| `POST /api/predict` | 检测并返回**带标注的图片**（base64）+ 明细，单张用 |
| `POST /api/detect` | 只返回 JSON（框坐标），供前端自己画，实时用 |

```bash
curl -X POST http://127.0.0.1:8000/api/predict \
     -F "file=@board.jpg" -F "model=solder" -F "iou=0.45"
```

`conf` 不传 → 用逐类推荐阈值；传了 → 统一阈值覆盖。

---

## 模型与阈值

```
models/
├─ solder_yolo26m_800.onnx    78 MB   9 类，imgsz 800
├─ bare_yolo26s_1024.onnx     37 MB   7 类，imgsz 1024
├─ models.json                       展示名与逐类阈值
└─ README.md                         权重来源与导出方法
```

逐类阈值来自各自的模型卡（val 上 F1 最优点）：

| solder（9 类） | | bare（7 类） | |
|---|---|---|---|
| 少锡 | 0.297 | 缺孔 | 0.745 |
| 多锡 | 0.349 | 鼠咬 | 0.484 |
| 连锡 | 0.417 | 开路 | 0.770 |
| 空洞 | 0.249 | 短路 | 0.406 |
| 缺件 | 0.381 | 毛刺 | 0.382 |
| 偏移 | 0.389 | 余铜 | 0.330 |
| 烧焦 | 0.224 | 针孔 | 0.571 |
| 损伤 | 0.214 | | |
| 氧化 | 0.228 | | |

**加模型不用改代码**：把 ONNX 放进 `models/`，在 `models.json` 里加一段 `label` / `global` / `per_class`，
前端下拉框自动出现。类别名和输入尺寸从 ONNX 元数据读取。文件名以 `_640` / `_320` / `_int8`
结尾的视为备用导出，不会被列出。

---

## 配置

| 环境变量 | 默认 | 说明 |
|---|---|---|
| `PCB_HOST` | `0.0.0.0` | 监听地址，改 `127.0.0.1` 只允许本机 |
| `PCB_PORT` | `8000` | 端口 |
| `PCB_MODEL_DIR` | `./models` | 模型目录 |
| `PCB_PRELOAD` | `1` | 启动时后台预热模型（关掉则首次请求慢） |

前端可调：`templates/index.html` 里 `live.maxDim`（抓帧长边，默认 1600）、JPEG 质量（0.85）。

---

## 性能参考（CPU，i5-11400H）

| 项目 | 结果 |
|---|---|
| solder（imgsz 800） | 单帧 0.45–1.0 s |
| bare（imgsz 1024） | 单帧 0.5–1.2 s |
| 整图往返（含编码） | 1.0–1.4 s |

实时模式的画面是流畅的，但**检测框大约每秒刷新一次**——这是模型计算量决定的。
要更快只能换小模型或做 int8 量化。

---

## Docker

```bash
docker build -t pcb-defect-web .
docker run -d -p 8000:8000 --name pcb-web pcb-defect-web
```

镜像里 `gunicorn` 必须单 worker（每个 worker 都会加载一份模型），并发靠线程。

---

## 已知限制

- `solder_void` 容易与 `insufficient_solder` 混淆；`burn` 召回偏低（约 62%）；暗光照片效果下降（模型卡自述）
- 实时模式的框刷新受限于推理速度，约 1 次/秒
- 模型许可为 research-use（数据集来源混合），Ultralytics 为 AGPL-3.0；商用前请确认授权