# PCB 缺陷检测 —— 本地部署说明

用 `best.pt`（YOLO26n，6 类 PCB 缺陷）做一个**本地网页**：浏览器上传图片 → 自动标注 → 看明细 / 导 CSV。

6 类：`missing_hole` 缺孔 · `mouse_bite` 鼠咬 · `open_circuit` 开路 · `short` 短路 · `spur` 毛刺 · `spurious_copper` 余铜

---

## 1. 目录内容

```
webapp/
├─ app_flask.py        ← 推荐：真网页（上传/拖拽/表格/导CSV），带 JSON 接口
├─ templates/
│  └─ index.html       ← 页面（纯原生 JS，不依赖任何国外 CDN）
├─ app_gradio.py       ← 备选：Gradio 版，代码更短，适合快速验证
├─ infer_cli.py        ← 批处理：单图/整目录 → 框图 + JSON，不启服务
├─ requirements.txt
└─ README.md
```

模型默认路径是 `../pcb_defect_yolo26n_zip/pcb_defect_yolo26n/weights/best.pt`，
想换位置就设环境变量 `PCB_WEIGHTS`，或改 `app_flask.py` 顶部的 `WEIGHTS`。

---

## 2. 装环境（只做一次）

> ⚠️ **本机现在出站 HTTPS 是断的**（DNS 被解析到 `198.18.0.250`，TLS 握手失败），
> `pip install` 会卡住。装之前先解决网络（关掉/修好代理，或换台能上网的机器）。

**Python 必须是 3.10 / 3.11**（本机默认的 3.14 装不了 torch）。

```powershell
cd C:\Users\yuzij\Documents\app\webapp
"C:\Program Files\Python310\python.exe" -m venv ..\venv310
..\venv310\Scripts\activate

# 有 NVIDIA 卡（RTX 3050 4GB）：装 CUDA 版 torch
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124
# 没有卡就装 CPU 版：pip install torch torchvision

pip install -r requirements.txt
```

网络慢就用镜像：

```powershell
pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

验证：

```powershell
python -c "import torch, ultralytics; print(torch.__version__, torch.cuda.is_available())"
```

---

## 3. 启动网页

**最省事：双击 `start.bat`** —— 自动检查环境、启动服务、等端口就绪后自动打开浏览器。
关闭那个黑窗口 = 停止服务。

```
双击 start.bat
→ 本机浏览器自动打开 http://127.0.0.1:8000/
→ 同窗口会打印「局域网访问: http://192.168.x.x:8000/」
```

可选环境变量（cmd 里 `set PCB_PORT=8080` 后再双击，或用命令行跑）：

| 变量 | 作用 |
|---|---|
| `PCB_PORT=8080` | 换端口 |
| `PCB_NO_BROWSER=1` | 只起服务，不自动开浏览器（做开机自启时用） |
| `PCB_HOST=127.0.0.1` | 只允许本机访问 |

手动启动（等价于双击）：

```powershell
python app_flask.py
```

浏览器打开 <http://127.0.0.1:8000> ，拖图片进去、点「开始检测」。

- 想让**局域网其它电脑/手机**访问：默认已经监听 `0.0.0.0`，
  用 `http://<本机IP>:8000` 即可（Windows 防火墙要放行 8000 端口，见第 6 节）。
- 只想快速看效果：`python app_gradio.py` → <http://127.0.0.1:7860>

> ⚠️ **`start.bat` 里只能写 ASCII 字符**。在 .bat 里塞中文（UTF-8 多字节）会让 cmd
> 按字节读行时错位，出现 `'CB' is not recognized...` 这类莫名其妙的报错，
> 后面的命令还会被静默跳过。中文提示一律交给 Python 输出。

---

## 4. 批处理（不进网页，直接跑一批图）

```powershell
python infer_cli.py D:\pcb_images\                    # 整目录
python infer_cli.py D:\pcb_images\a.jpg --conf 0.2    # 单张，降阈值
python infer_cli.py D:\pcb_images\ --json             # 只吐 JSON 给别的程序用
```

每张图旁边生成 `xxx_pred.jpg`（画框图）和 `xxx.json`（框坐标+置信度）。

---

## 5. 接口（给你的系统对接）

```bash
curl -X POST http://127.0.0.1:8000/api/predict -F "file=@a.jpg" -F "conf=0.25" -F "iou=0.7"
```

```json
{
  "ok": true,
  "count": 2,
  "image": "data:image/jpeg;base64,...",
  "detections": [
    {"cls": 0, "name": "missing_hole", "cn": "缺孔", "conf": 0.8231,
     "xyxy": [412.5, 180.0, 460.2, 232.7], "w": 47.7, "h": 52.7}
  ],
  "summary": "共 2 个缺陷：missing_hole(缺孔)×1，short(短路)×1",
  "size": {"w": 1920, "h": 1080}
}
```

坐标是**原图像素坐标**（左上 x1,y1，右下 x2,y2），可以直接拿来画到你的原图上。

---

## 6. 上线/长期运行的注意点

- **别用 `flask run --debug`**，也别开多 worker：每个进程都会加载一份模型，4GB 显存会被吃光。
  生产建议 `waitress-serve --port=8000 app_flask:app`（Windows 友好，单进程多线程）。
- 模型在进程启动时加载一次并常驻，单张推理不用重建。
- 4GB 显存下 `imgsz=640` 稳定；`imgsz=1280` 想用的话先压 `conf` 并实测显存。
- 现场产线要做「多相机并发」时，改成「图像队列 + 单推理线程」，别让 HTTP 线程直接抢 GPU。

---

## 7. Docker 部署（推荐给"换台机器/上服务器"）

本机双击 `start.bat` 和 Docker 二选一即可。Docker 的好处：换任何装了 Docker 的机器
（Linux 服务器、NAS、云主机）都能一条命令跑起来，不用管 Python 版本和依赖。

```bash
cd webapp

# 1) 构建（首次约 3–8 分钟，主要在下 torch；镜像约 1.5–2 GB）
docker build -t pcb-defect-web:latest .

# 2) 运行
docker run -d --name pcb-web -p 8000:8000 --restart unless-stopped pcb-defect-web:latest

# 3) 看状态 / 日志
docker ps
docker logs -f pcb-web
```

或用 compose（等价，还能顺手改端口/资源限制）：

```bash
docker compose up -d --build
docker compose logs -f
docker compose down
```

访问 `http://<宿主机IP>:8000`。

**镜像里的几个关键决定：**

| 决定 | 原因 |
|---|---|
| `ultralytics==8.4.215` 钉版本 | 与训练时的版本一致，避免权重结构不兼容 |
| torch 走 `/whl/cpu` 索引 | 默认会拉 2 GB+ 的 CUDA 包，CPU 版只要 ~200 MB |
| `gunicorn --workers 1 --threads 4` | **worker 必须是 1**：每个 worker 各加载一份模型，多开只吃内存不提速；并发靠线程 |
| 非 root 用户运行 | 容器逃逸面更小 |
| 权重烘进镜像 + 同时挂载 | 镜像自包含；`./models/best.pt` 换成新模型后 `restart` 即可热替换 |
| `HEALTHCHECK` | 编排系统能判断"模型加载完没有"，而不是进程在就算健康 |

**GPU 版**（可选）：`Dockerfile.gpu` 用 `pytorch/pytorch:*-cuda12.4` 基础镜像，
镜像会涨到 6–8 GB，单张推理从 ~60 ms 降到个位数毫秒。宿主机需要驱动 +
nvidia-container-toolkit，运行加 `--gpus all`（compose 里用 `deploy.resources.devices`）。

**注意：**
- 容器里不要改 `PCB_HOST`，保持 `0.0.0.0`，否则端口映射不进去。
- 想要多副本横向扩容要先想清楚：每个副本一份模型（CPU 版 ~1 GB 内存/份）。
- 权重是 AGPL-3.0，镜像对外分发时注意许可义务。

---

## 8. 提醒（模型本身的边界）

- 训练集是绿色 PCB 板的正视照片；**换光照/换板型/微距镜头要先小批量试**。
- `spur`（毛刺）是最弱的一类（混淆矩阵对角仅 0.74），漏检偏多；这一类关键就降 `conf` 到 0.15 左右或补样本重训。
- 背景有约 7–11% 的误报率，纯空板图可能报出 1 个假框。
- 权重是 **AGPL-3.0**：内部使用没问题，对外商用需评估授权。