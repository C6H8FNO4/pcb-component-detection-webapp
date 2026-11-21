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

.PARAMETER Venv
    复用已有虚拟环境（跳过建 venv）

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
    [string]$Venv = "",
    [string]$SitePackages = "",
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
$venvPyMaybe = if ($Venv) { Join-Path $Venv "Scripts\python.exe" } else { "" }

if ($SitePackages) {
    $PyVer = "3.10"
    Ok "跳过 Python 探测（使用预置 site-packages）"
}
elseif ($venvPyMaybe -and (Test-Path $venvPyMaybe)) {
    # 已有 venv：直接用它，不用探测系统 Python
    $PyVer = (& $venvPyMaybe -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null | Select-Object -First 1)
    $Python = ""
    Ok "复用 venv：$Venv（Python $PyVer）"
}
elseif (-not $Python) {
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
if (-not $SitePackages -and -not $Python -and -not ($venvPyMaybe -and (Test-Path $venvPyMaybe))) { Die "找不到 Python 3.10–3.12" }
if (-not $PyVer) { Die "无法确定 Python 版本" }
Ok "Python $PyVer"
if (-not $EMBED.ContainsKey($PyVer)) { Die "没有对应的 python-embed 版本：$PyVer" }

# ---------------------------------------------------------------- 2. venv + 依赖
$work = Join-Path $Root $WorkDir
$venv = if ($Venv) { $Venv } else { Join-Path $work "venv" }
$venvPy = Join-Path $venv "Scripts\python.exe"
New-Item -ItemType Directory -Force -Path $work | Out-Null

if ($SitePackages) {
    Ok "使用预置 site-packages: $SitePackages"
} elseif ($SkipDeps -and (Test-Path $venvPy)) {
    Ok "复用已有 venv（-SkipDeps）"
} else {
    Step "创建 venv 并安装依赖"
    # 只在“自己建的临时 venv”时清理；-Venv 指向的现有环境绝不删除
    if (-not $Venv -and (Test-Path $venv)) { Remove-Item -Recurse -Force $venv }
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

# --- MSVC 运行库：torch 的 c10.dll 依赖 msvcp140.dll，干净系统上没有会直接崩 ---
$crtDlls = @("msvcp140.dll", "msvcp140_1.dll", "msvcp140_2.dll",
             "vcruntime140.dll", "vcruntime140_1.dll", "concrt140.dll")
$copied = 0
foreach ($dll in $crtDlls) {
    $src = Join-Path $env:SystemRoot "System32\$dll"
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $pyDir $dll) -Force
        $copied++
    } else {
        Write-Host "    [!] 本机缺少 $dll（没装 VC++ 运行库），将跳过" -ForegroundColor Yellow
    }
}
if ($copied -lt 3) {
    Write-Host "    [!] 警告：只打包到 $copied 个运行库 DLL。目标机器可能需要另外安装 VC++ 2015-2022 x64 运行库" -ForegroundColor Yellow
    Write-Host "        下载：https://aka.ms/vs/17/release/vc_redist.x64.exe" -ForegroundColor Yellow
} else {
    Ok "已打包 $copied 个 MSVC 运行库 DLL（目标机器无需另装 VC++ 运行库）"
}

# 打开 site-packages 搜索
$pthName = Get-ChildItem $pyDir -Filter "*._pth" | Select-Object -First 1
$pthVer = ($pthName.Name -replace "python", "") -replace "._pth", ""
@("python$pthVer.zip", ".", "Lib\site-packages", "import site") | Set-Content -Path $pthName.FullName -Encoding ascii
Ok "._pth 已配置"

# 复制 site-packages
$srcSp = if ($SitePackages) { $SitePackages } else { Join-Path $venv "Lib\site-packages" }
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

# 使用说明（UTF-8，记事本可直接打开）
$readme = @"
PCB 缺陷检测 · 网页版（便携包）
================================

零安装：不用装 Python / pip / VC++ 运行库，也不用联网。解压后双击 start.bat（或 启动.bat）。

怎么用
  1. 解压到任意目录（路径尽量不含空格）
  2. 双击 start.bat
     · 会弹出一个控制台窗口（服务日志，关掉即停止服务）
     · 浏览器自动打开 http://127.0.0.1:8000/
  3. 页面有两个页签：
       单张检测 —— 拖图片进去 / 选图，自动标注 + 明细，可导出 CSV
       实时检测 —— 摄像头，或「抓取窗口/屏幕」把别的窗口当视频源连续检测

想直接从实时页开始：http://127.0.0.1:8000/?tab=live

两个模型（页面右上角切换）
  solder_yolo26m_800.onnx   焊接/装配缺陷 9 类（少锡 多锡 连锡 空洞 缺件 偏移 烧焦 损伤 氧化）
  bare_yolo26s_1024.onnx    裸板缺陷 7 类（缺孔 鼠咬 开路 短路 毛刺 余铜 针孔）

局域网访问
  服务监听 0.0.0.0:8000，启动时控制台会打印局域网地址。
  需要管理员放行一次：
    netsh advfirewall firewall add rule name="PCB-Web-8000" dir=in action=allow protocol=TCP localport=8000
  注意：通过 http:// 用局域网 IP 访问时，浏览器不授权摄像头和屏幕抓取（要求 https），单张检测照常可用。

性能参考（CPU）
  solder (imgsz 800)   单帧约 0.45–1.0 秒
  bare   (imgsz 1024)  单帧约 0.5–1.2 秒
  实时模式画面流畅，但检测框约每秒刷新一次（受模型计算量限制）。

改端口
  命令行设置环境变量后再启动：
    set PCB_PORT=8080
    start.bat

目录
  python\       便携 Python + 全部依赖（含 VC++ 运行库，无需另装）
  app\          服务端与网页
  启动.bat      start.bat 的中文名，两者内容相同

常见问题
  · 双击窗口一闪而过：用命令行进目录执行 start.bat 看报错；多半是解压不完整
  · 杀毒软件报警：便携 Python 常被误报，把整个文件夹加白名单
  · 端口被占用：按上面「改端口」换 8080
  · 页面显示「models/ 里没找到模型」：app\models\ 里的 .onnx 丢了，重新解压
"@
Set-Content -Path (Join-Path $pkg "使用说明.txt") -Value $readme -Encoding utf8
Ok "使用说明.txt 已写入"

# ---------------------------------------------------------------- 4. 自检
Step "便携包自检"
$env:YOLO_CONFIG_DIR = Join-Path $appDir ".ultralytics"
$env:PCB_NO_BROWSER = "1"
$prevEap = $ErrorActionPreference
$ErrorActionPreference = "Continue"   # python 往 stderr 写 warning 时别当致命错误
$out = & (Join-Path $pyDir "python.exe") -c "import sys,flask,cv2,numpy,onnx,onnxruntime;from importlib.metadata import version as v;print('flask',v('flask'));print('cv2',cv2.__version__);print('numpy',numpy.__version__);print('onnxruntime',onnxruntime.__version__)" 2>&1
$pyExit = $LASTEXITCODE
$ErrorActionPreference = $prevEap
$out | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
if ($pyExit -ne 0) { Die "便携 python 自检失败" }
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