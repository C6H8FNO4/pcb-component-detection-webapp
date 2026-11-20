@echo off
chcp 65001 >nul
setlocal
title PCB Defect Detection Server

rem ===================================================================
rem  Double-click to start the local web app + open the browser.
rem  Close this window to stop the server.
rem  Optional env: PCB_PORT=8080      PCB_NO_BROWSER=1
rem  NOTE: keep this .bat ASCII-only. Chinese text inside a .bat breaks
rem        cmd line parsing under UTF-8; Chinese messages come from Python.
rem ===================================================================

cd /d "%~dp0"

set "PORT=8000"
if defined PCB_PORT set "PORT=%PCB_PORT%"
set "PY=%~dp0..\venv310\Scripts\python.exe"

set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
set PYTHONUNBUFFERED=1
set "YOLO_CONFIG_DIR=%~dp0.ultralytics"
set "TORCHINDUCTOR_CACHE_DIR=%~dp0.ultralytics\torch_cache"

echo ==========================================
echo    PCB Defect Detection - Local Web App
echo ==========================================
echo.

if not exist "%PY%" goto novenv

netstat -ano | findstr ":%PORT% " | findstr /i "LISTENING" >nul 2>&1
if not errorlevel 1 goto busy

if "%PCB_NO_BROWSER%"=="1" goto serve
start "" /b "%PY%" "%~dp0open_browser.py" "http://127.0.0.1:%PORT%/"

:serve
echo Starting... first load takes about 2 seconds.
echo Close this window or press Ctrl+C to stop.
echo ------------------------------------------
echo.
"%PY%" app_flask.py
echo.
echo Server stopped.
pause
exit /b 0

:busy
echo [INFO] Port %PORT% is already serving. Opening browser...
start "" "http://127.0.0.1:%PORT%/"
timeout /t 2 >nul
exit /b 0

:novenv
echo [ERROR] Python venv not found:
echo         %PY%
echo.
echo   Install it once:
echo     "C:\Program Files\Python310\python.exe" -m venv ..\venv310
echo     ..\venv310\Scripts\python.exe -m pip install torch torchvision
echo     ..\venv310\Scripts\python.exe -m pip install ultralytics flask
echo.
pause
exit /b 1