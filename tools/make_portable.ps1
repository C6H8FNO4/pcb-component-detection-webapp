<#
.SYNOPSIS
    把 Web 服务打包成 Windows 便携包（python-embed + 预装依赖 + 模型）。

.DESCRIPTION
    流程：
      1. 用指定 Python 建一个临时 venv
      2. 装 torch（按 -TorchIndex 选 CPU / CUDA 版本）+ requirements
      3. 下载对应版本的 python embeddable，套上 venv 的 site-packages
      4. 复制 app / templates / models，写启动脚本
      5. 压缩成 zip

    产物可直接解压双击启动，目标机器不需要装 Python。

.PARAMETER TorchIndex
    PyTorch 索引地址。例：
      https://download.pytorch.org/whl/cpu
      https://download.pytorch.org/whl/cu124

.PARAMETER Python
    用来建 venv 的 Python（默认 py -3.11）

.PARAMETER OutFile
    输出 zip 路径（默认 dist/pcb-webapp-portable-win64.zip）

.PARAMETER SkipDeps
    复用已有 venv，跳过 pip 安装（调试用）

.EXAMPLE
    .\tools\make_portable.ps1 -TorchIndex https://download.pytorch.org/whl/cpu
#>
param(
    [string]$TorchIndex = "https://download.pytorch.org/whl/cpu",
    [string]$Python = "",
    [string]$OutFile = "",
    [string]$WorkDir = "build_portable",
    [switch]$SkipDeps
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Die($m)  { Write-Host "`n[失败] $m" -ForegroundColor Red; exit 1 }

# python-embed 版本表（embeddable 只到 3.11.9 / 3.10.11 这些末端版本）
$EMBED = @{
    "3.12" = "https://www.python.org/ftp/python/3.12.10/python-3.12.10-embed-amd64.zip"
    "3.11" = "https://www.python.org/ftp/python/3.11.9/python-3.11.9-embed-amd64.zip"
    "3.10" = "https://www.python.org/ftp/python/3.10.11/python-3.10.11-embed-amd64.zip"
}

if (-not $OutFile) { $OutFile = Join-Path $Root "dist\pcb-webapp-portable-win64.zip" }

# ---------------------------------------------------------------- 1. 选 Python
Step "准备 Python"
if (-not $Python) {
    foreach ($cand in @(@("py", "-3.11"), @("py", "-3.12"), @("py", "-3.10"), @("python"))) {
        try {
            $lead = if ($cand.Length -gt 1) { $cand[1..($cand.Length - 1)] } else { @() }
            $v = (& $cand[0] @lead -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null | Select-Object -First 1)
            if ($v -match "^(3\.(1[0-2]))$") { $Python = ($cand -join " "); $PyVer = $Matches[1]; break }
        } catch { }
    }
} else {
    $PyVer = (& $Python -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null | Select-Object -First 1)
}
if (-not $Python -or -not $PyVer) { Die "找不到 Python 3.10–3.12" }
Ok "Python $PyVer  ($Python)"
if (-not $EMBED.ContainsKey($PyVer)) { Die "没有对应的 python-embed 版本：$PyVer" }

# ---------------------------------------------------------------- 2. venv + 依赖
$work = Join-Path $Root $WorkDir
$venv = Join-Path $work "venv"
$venvPy = Join-Path $venv "Scripts\python.exe"
New-Item -ItemType Directory -Force -Path $work | Out-Null

if ($SkipDeps -and (Test-Path $venvPy)) {
    Ok "复用已有 venv（-SkipDeps）"
} else {
    Step "创建 venv 并安装依赖"
    if (Test-Path $venv) { Remove-Item -Recurse -Force $venv }
    # 正确拆分 "py -3.11" 这类带参数的解释器（不能对数组取 [1..100]，会产生大量 $null）
    $pyParts = $Python.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
    $pyExe = $pyParts[0]
    $pyArgs = if ($pyParts.Length -gt 1) { $pyParts[1..($pyParts.Length - 1)] } else { @() }
    & $pyExe @pyArgs -m venv $venv
    if (-not (Test-Path $venvPy)) { Die "venv 创建失败" }
    Ok "venv 就绪"

    & $venvPy -m pip install -q --prefer-binary --timeout 60 --retries 3 torch torchvision --index-url $TorchIndex
    if ($LASTEXITCODE -ne 0) { Die "torch 安装失败（$TorchIndex）" }
    Ok "torch 安装完成"

    & $venvPy -m pip install -q --prefer-binary --timeout 60 --retries 3 -r (Join-Path $Root "requirements.txt")
    if ($LASTEXITCODE -ne 0) { Die "依赖安装失败" }
    Ok "依赖安装完成"
}

# ---------------------------------------------------------------- 3. 组装目录
Step "组装便携目录"
$pkg = Join-Path $work "pcb-webapp-portable"
if (Test-Path $pkg) { Remove-Item -Recurse -Force $pkg }
New-Item -ItemType Directory -Force -Path $pkg | Out-Null

$embedZip = Join-Path $work "python-embed.zip"
if (-not (Test-Path $embedZip)) {
    Invoke-WebRequest -Uri $EMBED[$PyVer] -OutFile $embedZip -UseBasicParsing
}
$pyDir = Join-Path $pkg "python"
New-Item -ItemType Directory -Force -Path $pyDir | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::ExtractToDirectory($embedZip, $pyDir)
Ok "python-embed 解压完成"

# 打开 site-packages 搜索
$pthName = Get-ChildItem $pyDir -Filter "*._pth" | Select-Object -First 1
$pthVer = ($pthName.Name -replace "python", "") -replace "._pth", ""
@("python$pthVer.zip", ".", "Lib\site-packages", "import site") | Set-Content -Path $pthName.FullName -Encoding ascii
Ok "._pth 已配置"

# 复制 site-packages
$srcSp = Join-Path $venv "Lib\site-packages"
$dstSp = Join-Path $pyDir "Lib\site-packages"
New-Item -ItemType Directory -Force -Path $dstSp | Out-Null
robocopy $srcSp $dstSp /E /NFL /NDL /NJH /NJS /R:1 /W:1 | Out-Null
if ($LASTEXITCODE -ge 8) { Die "复制 site-packages 失败 (robocopy $LASTEXITCODE)" }
Get-ChildItem $dstSp -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
Ok ("site-packages {0:N0} MB" -f ((Get-ChildItem $dstSp -Recurse -File | Measure-Object Length -Sum).Sum / 1MB))

# 复制应用文件
$appDir = Join-Path $pkg "app"
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
Copy-Item (Join-Path $Root "app_flask.py") $appDir -Force
Copy-Item (Join-Path $Root "open_browser.py") $appDir -Force
Copy-Item (Join-Path $Root "templates") $appDir -Recurse -Force
Copy-Item (Join-Path $Root "models") $appDir -Recurse -Force
# 模型目录只保留 .onnx 与配置
Get-ChildItem (Join-Path $appDir "models") -File | Where-Object { $_.Extension -eq ".pt" } | Remove-Item -Force -ErrorAction SilentlyContinue
Ok "应用文件已复制"

# 启动脚本（ASCII 内容，避免 cmd 解析问题）
$bat = @'
@echo off
chcp 65001 >nul
setlocal
title PCB Defect Detection Server
cd /d "%~dp0"
set "PY=%~dp0python\python.exe"
set "APP=%~dp0app"
if not exist "%PY%" goto nopy
set PYTHONUTF8=1
set PYTHONIOENCODING=utf-8
set PYTHONUNBUFFERED=1
set "YOLO_CONFIG_DIR=%APP%\.ultralytics"
set "TORCHINDUCTOR_CACHE_DIR=%APP%\.cache\torch"
set "MPLCONFIGDIR=%APP%\.cache\mpl"
set "PCB_HOST=0.0.0.0"
set "PCB_PORT=8000"
echo ==========================================
echo    PCB Defect Detection - portable
echo ==========================================
echo  Local : http://127.0.0.1:8000/
echo  Stop  : close this window or press Ctrl+C
echo.
if not "%PCB_NO_BROWSER%"=="1" start "" /b "%PY%" "%APP%\open_browser.py" "http://127.0.0.1:8000/"
"%PY%" "%APP%\app_flask.py"
echo.
echo Server stopped.
pause
exit /b 0
:nopy
echo [ERROR] portable python not found: %PY%
pause
exit /b 1
'@
Set-Content -Path (Join-Path $pkg "启动.bat") -Value $bat -Encoding ascii
Copy-Item (Join-Path $pkg "启动.bat") (Join-Path $pkg "start.bat") -Force
Ok "启动脚本已写入"

# ---------------------------------------------------------------- 4. 自检
Step "便携包自检"
$env:YOLO_CONFIG_DIR = Join-Path $appDir ".ultralytics"
$env:PCB_NO_BROWSER = "1"
$out = & (Join-Path $pyDir "python.exe") -c "import torch,ultralytics,flask,cv2;print('torch',torch.__version__);print('cuda',torch.cuda.is_available());print('ultralytics',ultralytics.__version__)" 2>&1
$out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
if ($LASTEXITCODE -ne 0) { Die "便携 python 自检失败" }
Ok "便携 python 可用"

# ---------------------------------------------------------------- 5. 压缩
Step "压缩"
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
$sevenZip = @("C:\Program Files\7-Zip\7z.exe", "C:\Program Files (x86)\7-Zip\7z.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if ($sevenZip) {
    & $sevenZip a -tzip -mx=3 -mmt=on $OutFile $pkg | Out-Null
} else {
    Compress-Archive -Path $pkg -DestinationPath $OutFile -CompressionLevel Optimal
}
if (-not (Test-Path $OutFile)) { Die "压缩失败" }
Ok ("产物 {0}  ({1:N0} MB)" -f $OutFile, ((Get-Item $OutFile).Length / 1MB))