#requires -Version 5.1
<#
.SYNOPSIS
    PCB 缺陷检测 —— Web 服务一键安装脚本（Windows）

.DESCRIPTION
    1) 找一个可用的 Python（3.9–3.12）
    2) 在 webapp\.venv 建虚拟环境
    3) 安装依赖（onnxruntime 推理，不需要 torch）
    4) 检查 models\ 下的 ONNX 权重
    5) 默认直接启动服务

.PARAMETER Python
    手动指定 Python 解释器路径，例如 "C:\Program Files\Python310\python.exe"

.PARAMETER NoStart
    只安装，不启动服务

.PARAMETER CpuOnly
    保留参数（兼容旧用法，无实际作用）

.EXAMPLE
    .\install.ps1
    .\install.ps1 -NoStart
    .\install.ps1 -Python "C:\Program Files\Python310\python.exe"
#>
param(
    [string]$Python = "",
    [switch]$NoStart,
    [switch]$CpuOnly
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    [!]  $msg" -ForegroundColor Yellow }
function Fail($msg)       { Write-Host "`n[失败] $msg" -ForegroundColor Red; exit 1 }

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  PCB 缺陷检测 · Web 服务安装" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "目录: $PSScriptRoot"

# ---------------------------------------------------------------- 1. 选 Python
Write-Step "查找 Python（需要 3.9 – 3.12）"

function Test-PyVersion($exeArgs) {
    try {
        # 注意：单个元素时 [1..0] 会退化成 (1,0)，必须显式判断
        $lead = if ($exeArgs.Length -gt 1) { $exeArgs[1..($exeArgs.Length - 1)] } else { @() }
        $out = & $exeArgs[0] @lead -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null
        return ($out | Select-Object -First 1)
    } catch { return $null }
}

function Invoke-Py($exeArgs, [string[]]$rest) {
    $lead = if ($exeArgs.Length -gt 1) { $exeArgs[1..($exeArgs.Length - 1)] } else { @() }
    & $exeArgs[0] @lead @rest
}

$candidates = @()
if ($Python) {
    $candidates += ,@($Python)
} else {
    foreach ($v in @("-3.12", "-3.11", "-3.10", "-3.9")) {
        $candidates += ,@("py", $v)
    }
    $candidates += ,@("python")
    $candidates += ,@("C:\Program Files\Python311\python.exe")
    $candidates += ,@("C:\Program Files\Python310\python.exe")
}

$pyExe = $null
foreach ($cand in $candidates) {
    $ver = Test-PyVersion $cand
    if ($ver) {
        $parts = $ver.Split(".")
        $maj = [int]$parts[0]; $min = [int]$parts[1]
        $shown = ($cand -join " ")
        if ($maj -eq 3 -and $min -ge 9 -and $min -le 12) {
            $pyExe = $cand
            Write-Ok "使用 $shown  (Python $ver)"
            break
        } else {
            Write-Warn2 "跳过 $shown  (Python $ver，需要 3.9–3.12)"
        }
    }
}

if (-not $pyExe) {
    Fail @"
找不到可用的 Python 3.9–3.12。

请先装一个（任选其一）：
  · winget install Python.Python.3.11
  · https://www.python.org/downloads/release/python-3119/

装好后重试，或用 -Python 指定路径：
  .\install.ps1 -Python "C:\Program Files\Python311\python.exe"
"@
}

# ---------------------------------------------------------------- 2. 建虚拟环境
Write-Step "创建虚拟环境 .venv"
$venv = Join-Path $PSScriptRoot ".venv"
$venvPy = Join-Path $venv "Scripts\python.exe"

if (Test-Path $venvPy) {
    Write-Ok "已存在，复用"
} else {
    Invoke-Py $pyExe @("-m", "venv", $venv)
    if (-not (Test-Path $venvPy)) { Fail "虚拟环境创建失败" }
    Write-Ok "已创建 $venv"
}

& $venvPy -m pip install --upgrade pip --quiet
Write-Ok ("pip " + (& $venvPy -m pip --version).Split(" ")[1])

# ---------------------------------------------------------------- 3. 装依赖

Write-Step "安装其余依赖（ultralytics / flask / opencv …）"
& $venvPy -m pip install --quiet -r (Join-Path $PSScriptRoot "requirements.txt")
if ($LASTEXITCODE -ne 0) { Fail "依赖安装失败。可尝试国内镜像：-i https://pypi.tuna.tsinghua.edu.cn/simple" }
Write-Ok "依赖安装完成"

Write-Step "自检"
$check = & $venvPy -c "import flask,cv2,numpy,onnx,onnxruntime;print('flask',flask.__version__);print('onnxruntime',onnxruntime.__version__)" 2>&1
$check | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
if ($LASTEXITCODE -ne 0) { Fail "依赖自检失败" }

# ---------------------------------------------------------------- 4. 检查模型
Write-Step "检查模型权重"
$modelDir = Join-Path $PSScriptRoot "models"
$need = @{
    "solder_yolo26m_800.onnx" = "焊接缺陷 9 类 (YOLO26m, imgsz 800)"
    "bare_yolo26s_1024.onnx"  = "裸板缺陷 7 类 (YOLO26s, imgsz 1024)"
}
$missing = @()
foreach ($f in $need.Keys) {
    $p = Join-Path $modelDir $f
    if (Test-Path $p) {
        $mb = [math]::Round((Get-Item $p).Length / 1MB, 1)
        Write-Ok "$f  ($mb MB) —— $($need[$f])"
    } else {
        $missing += $f
        Write-Warn2 "缺少 $f —— $($need[$f])"
    }
}
if ($missing.Count -gt 0) {
    Write-Warn2 "可以在没有模型的情况下启动（界面会显示"models/ 里没找到模型"）"
    Write-Warn2 "补齐方法见 models\README.md"
}

# ---------------------------------------------------------------- 5. 启动
if ($NoStart) {
    Write-Host "`n安装完成。启动方式：" -ForegroundColor Green
    Write-Host "  .\.venv\Scripts\python.exe app_flask.py" -ForegroundColor White
    Write-Host "  或双击 start.bat" -ForegroundColor White
    exit 0
}

Write-Host "`n安装完成，正在启动服务…" -ForegroundColor Green
Write-Host "按 Ctrl+C 停止。`n" -ForegroundColor DarkGray
$env:YOLO_CONFIG_DIR = Join-Path $PSScriptRoot ".ultralytics"
& $venvPy app_flask.py