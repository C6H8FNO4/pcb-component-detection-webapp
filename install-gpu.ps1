#requires -Version 5.1
<#
.SYNOPSIS
    PCB 缺陷检测 Web 服务 —— 安装脚本（CPU / GPU）

.DESCRIPTION
    网页版推理用 onnxruntime，不需要 torch。
      · CPU  → onnxruntime      （约 60 MB）
      · GPU  → onnxruntime-gpu  （需系统已装 CUDA 12.x + cuDNN 9，约 250 MB）

    脚本会先用 nvidia-smi 探测显卡；有 GPU 时提供 GPU 选项。

.PARAMETER Gpu
    直接装 GPU 版（onnxruntime-gpu）

.PARAMETER Cpu
    直接装 CPU 版

.PARAMETER Venv
    复用已有虚拟环境（默认本目录 .venv）

.PARAMETER Mirror
    使用国内 PyPI 镜像

.PARAMETER SkipDeps
    跳过 pip 安装（环境已就绪时只做检查）

.PARAMETER NoStart
    只安装，不启动服务

.EXAMPLE
    .\install-gpu.ps1
    .\install-gpu.ps1 -Gpu
    .\install-gpu.ps1 -Cpu -Mirror -NoStart
#>
param(
    [switch]$Gpu,
    [switch]$Cpu,
    [string]$Venv = "",
    [switch]$Mirror,
    [switch]$SkipDeps,
    [switch]$NoStart,
    [string]$Python = ""
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Warn2($m){ Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "`n[失败] $m" -ForegroundColor Red; exit 1 }

$MIRROR_URL = "https://pypi.tuna.tsinghua.edu.cn/simple"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  PCB 缺陷检测 · Web 安装（CPU / GPU）" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "目录: $PSScriptRoot"

# ---------------------------------------------------------------- 1. 探测显卡
Step "探测显卡"
$gpuName = ""; $driverVer = ""
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    try {
        $line = (& nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>$null | Select-Object -First 1)
        if ($line -match "^(.*),\s*([0-9.]+)\s*,\s*(.*)$") {
            $gpuName = $Matches[1].Trim(); $driverVer = $Matches[2].Trim(); $vram = $Matches[3].Trim()
        }
    } catch { }
}
if ($gpuName) {
    Ok "NVIDIA $gpuName · 驱动 $driverVer · 显存 $vram"
    Write-Host "        （GPU 推理需要系统已装 CUDA 12.x + cuDNN 9；否则先用 CPU 版）" -ForegroundColor DarkGray
} else {
    Warn2 "没检测到 NVIDIA 显卡 —— 只能用 CPU 版"
}

# ---------------------------------------------------------------- 2. 选后端
if ($Gpu -and $Cpu) { Die "-Gpu 与 -Cpu 不能同时指定" }
if ($Gpu) { $useGpu = $true }
elseif ($Cpu) { $useGpu = $false }
elseif ($gpuName) {
    Write-Host ""
    Write-Host "选择推理后端：" -ForegroundColor White
    Write-Host "  [0] CPU   —— onnxruntime，约 60 MB，单帧 0.45–1.2 秒"
    Write-Host "  [1] GPU   —— onnxruntime-gpu，约 250 MB，需 CUDA 12.x + cuDNN 9"
    $ans = Read-Host "`n输入编号（直接回车 = 0，即 CPU）"
    $useGpu = ($ans -eq "1")
} else {
    $useGpu = $false
}
$pkgName = if ($useGpu) { "onnxruntime-gpu" } else { "onnxruntime" }
Ok "后端: $(if ($useGpu) {'GPU'} else {'CPU'})  →  $pkgName"

# ---------------------------------------------------------------- 3. Python
Step "查找 Python（需要 3.9 – 3.12）"
function Test-PyVersion($exeArgs) {
    try {
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
if ($Python) { $candidates += ,@($Python) }
else {
    foreach ($v in @("-3.12", "-3.11", "-3.10", "-3.9")) { $candidates += ,@("py", $v) }
    $candidates += ,@("python")
    $candidates += ,@("C:\Program Files\Python311\python.exe")
    $candidates += ,@("C:\Program Files\Python310\python.exe")
}
$pyExe = $null
foreach ($cand in $candidates) {
    $ver = Test-PyVersion $cand
    if ($ver) {
        $p = $ver.Split(".")
        if ([int]$p[0] -eq 3 -and [int]$p[1] -ge 9 -and [int]$p[1] -le 12) {
            $pyExe = $cand; Ok ("使用 " + ($cand -join " ") + "  (Python $ver)"); break
        } else { Warn2 ("跳过 " + ($cand -join " ") + "  (Python $ver)") }
    }
}
if (-not $pyExe) { Die "找不到 Python 3.9–3.12。安装：winget install Python.Python.3.11" }

# ---------------------------------------------------------------- 4. 虚拟环境
Step "准备虚拟环境"
if (-not $Venv) { $Venv = Join-Path $PSScriptRoot ".venv" }
$venvPy = Join-Path $Venv "Scripts\python.exe"
if (Test-Path $venvPy) { Ok "复用 $Venv" }
else {
    Invoke-Py $pyExe @("-m", "venv", $Venv)
    if (-not (Test-Path $venvPy)) { Die "虚拟环境创建失败" }
    Ok "已创建 $Venv"
}

# ---------------------------------------------------------------- 5. 依赖
if ($SkipDeps) {
    Warn2 "已指定 -SkipDeps：跳过所有 pip 安装"
} else {
    $pipCommon = @("--prefer-binary", "--timeout", "60", "--retries", "3", "--no-input")
    $idxArgs = if ($Mirror) { @("-i", $MIRROR_URL) } else { @() }

    Step "安装依赖（$pkgName + flask/opencv/onnx）"
    $args1 = @("install") + $pipCommon + $idxArgs + @($pkgName)
    & $venvPy -m pip @args1
    if ($LASTEXITCODE -ne 0) { Die "$pkgName 安装失败（可加 -Mirror）" }

    Step "安装其余依赖"
    $args2 = @("install") + $pipCommon + $idxArgs + @("-r", (Join-Path $PSScriptRoot "requirements.txt"))
    & $venvPy -m pip @args2
    if ($LASTEXITCODE -ne 0) { Die "依赖安装失败（可加 -Mirror）" }
    Ok "依赖就绪"
}

# ---------------------------------------------------------------- 6. 自检
Step "运行时自检"
$prev = $ErrorActionPreference
$ErrorActionPreference = "Continue"
$rc = & $venvPy -c @"
import onnxruntime as ort
print('onnxruntime  :', ort.__version__)
prov = ort.get_available_providers()
print('providers    :', ', '.join(prov))
print('cuda 可用    :', 'CUDAExecutionProvider' in prov)
"@ 2>&1
$ErrorActionPreference = $prev
$rc | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

if ($useGpu -and (($rc -join "`n") -notmatch "cuda 可用\s*:\s*True")) {
    Warn2 "选的是 GPU，但 CUDA provider 不可用"
    Warn2 "常见原因：没装 CUDA 12.x 运行库 / 缺少 cuDNN 9 / 显卡驱动过旧"
    Warn2 "可以先用 CPU 版：-Cpu"
} elseif ($useGpu) { Ok "GPU 推理可用" }

# ---------------------------------------------------------------- 7. 模型
Step "检查模型权重"
$need = @{
    "solder_yolo26m_800.onnx" = "焊接缺陷 9 类 (imgsz 800)"
    "bare_yolo26s_1024.onnx"  = "裸板缺陷 7 类 (imgsz 1024)"
}
foreach ($f in $need.Keys) {
    $fp = Join-Path $PSScriptRoot "models\$f"
    if (Test-Path $fp) { Ok ("{0}  ({1} MB)  {2}" -f $f, [math]::Round((Get-Item $fp).Length / 1MB, 1), $need[$f]) }
    else { Warn2 "缺少 $f —— $($need[$f])，见 models\README.md" }
}

# ---------------------------------------------------------------- 8. 启动
if ($NoStart) {
    Write-Host "`n安装完成。启动：`n  $venvPy app_flask.py" -ForegroundColor Green
    exit 0
}
Write-Host "`n安装完成，正在启动服务…（Ctrl+C 停止）`n" -ForegroundColor Green
$env:PYTHONUTF8 = "1"
& $venvPy app_flask.py