"""
启动器辅助脚本：等服务端口就绪后自动打开浏览器。
由 start.bat 在后台调用，也可以单独运行：
    python open_browser.py http://127.0.0.1:8000/
"""

import sys
import time
import urllib.request
import webbrowser

url = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8000/"

ready = False
for _ in range(120):          # 最多等 60 秒（0.5s × 120）
    try:
        urllib.request.urlopen(url, timeout=2).read(1)
        ready = True
        break
    except Exception:
        time.sleep(0.5)

try:
    webbrowser.open(url)
    print(f"[浏览器] 已打开 {url}" if ready else f"[浏览器] 服务未确认就绪，仍尝试打开 {url}")
except Exception as e:        # 没有默认浏览器时别把启动器搞崩
    print(f"[浏览器] 打开失败: {e}，请手动访问 {url}")