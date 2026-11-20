# ---------------------------------------------------------------------------
# PCB 缺陷检测 Web 服务 —— CPU 版镜像
#
# 构建（在 webapp 目录下，需带 models/best.pt）：
#     docker build -t pcb-defect-web:latest .
# 运行：
#     docker run -d --name pcb-web -p 8000:8000 --restart unless-stopped pcb-defect-web:latest
# 浏览器打开 http://localhost:8000
#
# 镜像体积约 1.5–2 GB（大头是 torch；CPU 版已是最小选择）
# ---------------------------------------------------------------------------
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    YOLO_CONFIG_DIR=/app/.ultralytics \
    MPLBACKEND=Agg

# opencv 运行时需要的动态库（libGL/libglib）；libgomp 是 torch 的 OpenMP
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 libgomp1 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# 先单独装 CPU 版 torch（走官方 cpu index，避免拉到 2 GB 的 CUDA 包）
RUN pip install --no-cache-dir torch torchvision \
        --index-url https://download.pytorch.org/whl/cpu \
 && pip install --no-cache-dir "ultralytics==8.4.215" flask gunicorn

# 应用代码（只拷需要的，不拷 start.bat / open_browser.py / 演示图）
COPY app_flask.py ./
COPY templates ./templates
COPY models ./models

# 非 root 运行
RUN useradd -m -u 1000 appuser \
 && mkdir -p /app/.ultralytics \
 && chown -R appuser:appuser /app
USER appuser

ENV PCB_WEIGHTS=/app/models/best.pt \
    PCB_HOST=0.0.0.0 \
    PCB_PORT=8000

EXPOSE 8000

# 容器就绪探针：能拿到首页即健康（模型在 import 时已加载完）
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/',timeout=3).status==200 else 1)"

# 关键：worker 必须为 1。每个 worker 都会各加载一份模型，
# 多 worker 只会白吃内存/显存，不会更快。并发靠 gthread 线程。
CMD ["gunicorn", "app_flask:app", \
     "--workers", "1", \
     "--worker-class", "gthread", \
     "--threads", "4", \
     "--timeout", "120", \
     "--bind", "0.0.0.0:8000", \
     "--access-logfile", "-", \
     "--error-logfile", "-"]