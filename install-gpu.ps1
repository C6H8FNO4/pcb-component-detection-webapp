#requires -Version 5.1
<#
.SYNOPSIS
    PCB 缺陷检测 Web 服务 —— 安装脚本（可选 GPU 后端）

.DESCRIPTION
    自动探测显卡与驱动，推荐合适的 CUDA 版本，按选择安装对应 PyTorch：
      [0] CPU         普通机器，无需显卡
      [1] CUDA 12.8   最新（驱动 >= 570）
      [2] CUDA 12.6   （驱动 >= 560）
      [3] CUDA 12.4   （驱动 >= 550）
      [4] CUDA 12.1   驱动较旧时用（驱动 >= 530）

    GPU 版 torch 下载约 2–3 GB，首次安装比较慢；CPU 版约 200 MB。

.PARAMETER Backend
    跳过菜单直接指定：cpu | cu128 | cu126 | cu124 | cu121

.PARAMETER Venv
    复用已有虚拟环境目录（默认本目录下的 .venv）

.PARAMETER Mirror
    使用国内 PyPI 镜像安装 ultralytics / flask 等（torch 仍走官方索引）

.PARAMETER SkipDeps
    跳过 pip 安装步骤（环境已备好时用，仅做检测与检查）

.PARAMETER UpgradePip
    顺便升级 pip（默认不做）

.PARAMETER NoStart
    只安装，不启动服务

.PARAMETER Force
    即使已是同类 torch 也强制重装

.EXAMPLE
    .\install-gpu.ps1
    .\install-gpu.ps1 -Backend cu124
    .\install-gpu.ps1 -Backend cpu -Mirror -NoStart
    .\install-gpu.ps1 -Backend cpu -SkipDeps -NoStart -Venv ..\venv310
#>
param(
    [ValidateSet("cpu", "cu128", "cu126", "cu124", "cu121", "")]
    [string]$Backend = "",
    [string]$Venv = "",
    [switch]$Mirror,
    [switch]$SkipDeps,
    [switch]$UpgradePip,
    [switch]$NoStart,
    [switch]$Force,
    [string]$Python = ""
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot

function Step($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "    [OK] $m" -ForegroundColor Green }
function Warn2($m){ Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "`n[失败] $m" -ForegroundColor Red; exit 1 }

$MIRROR_URL = "https://pypi.tuna.tsinghua.edu.cn/simple"

$CUDA_TABLE = @(
    [pscustomobject]@{ Key = "cu128"; Name = "CUDA 12.8"; Index = "https://download.pytorch.org/whl/cu128"; MinDriver = 570 },
    [pscustomobject]@{ Key = "cu126"; Name = "CUDA 12.6"; Index = "https://download.pytorch.org/whl/cu126"; MinDriver = 560 },
    [pscustomobject]@{ Key = "cu124"; Name = "CUDA 12.4"; Index = "https://download.pytorch.org/whl/cu124"; MinDriver = 550 },
    [pscustomobject]@{ Key = "cu121"; Name = "CUDA 12.1"; Index = "https://download.pytorch.org/whl/cu121"; MinDriver = 530 }
)

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  PCB 缺陷检测 · Web 安装（可选 GPU）" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "目录: $PSScriptRoot"

# ---------------------------------------------------------------- 1. 探测显卡
Step "探测显卡"
$gpuName = ""; $driverVer = ""; $vram = ""
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    try {
        $line = (& nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>$null | Select-Object -First 1)
        if ($line -match "^(.*),\s*([0-9.]+)\s*,\s*(.*)$") {
            $gpuName = $Matches[1].Trim(); $driverVer = $Matches[2].Trim(); $vram = $Matches[3].Trim()
        }
    } catch { }
}

$recommend = ""
if ($gpuName) {
    Ok "NVIDIA $gpuName  ·  驱动 $driverVer  ·  显存 $vram"
    $maj = 0; if ($driverVer -match "^(\d+)") { $maj = [int]$Matches[1] }
    foreach ($c in $CUDA_TABLE) { if ($maj -ge $c.MinDriver) { $recommend = $c.Key; break } }
    if ($recommend) {
        $rn = ($CUDA_TABLE | Where-Object Key -eq $recommend).Name
        Ok "按驱动版本推荐: $rn"
        if ($maj -ge 570) { Write-Host "        （驱动较新，也可以选更高的 CUDA；但 4GB 显存跑检测足够，不必追新）" -ForegroundColor DarkGray }
    } else {
        Warn2 "驱动偏旧（主版本 $maj < 530），只能装 CPU 版，或先升级显卡驱动"
        $recommend = "cpu"
    }
} else {
    Warn2 "没检测到 NVIDIA 显卡（或没装驱动）—— 只能用 CPU 版"
    $recommend = "cpu"
}

# ---------------------------------------------------------------- 2. 选后端
if ($Backend) {
    $chosen = $Backend
    Write-Host "`n使用命令行指定后端: $chosen" -ForegroundColor White
} else {
    Write-Host ""
    Write-Host "选择 PyTorch 后端（GPU 版下载 2–3 GB，CPU 版约 200 MB）：" -ForegroundColor White
    Write-Host "  [0] CPU          —— 无显卡也能跑，单帧约 0.5–1.2 秒"
    for ($i = 0; $i -lt $CUDA_TABLE.Count; $i++) {
        $c = $CUDA_TABLE[$i]
        $tag = if ($recommend -eq $c.Key) { "   <= 推荐" } else { "" }
        Write-Host ("  [{0}] {1,-11} —— 驱动 >= {2}{3}" -f ($i + 1), $c.Name, $c.MinDriver, $tag)
    }
    $def = if ($recommend) { $recommend } else { "cpu" }
    $ans = Read-Host "`n输入编号（直接回车 = 自动，即 $def）"
    if ([string]::IsNullOrWhiteSpace($ans) -or $ans -match "^[Aa]") { $chosen = $def }
    elseif ($ans -eq "0") { $chosen = "cpu" }
    elseif ($ans -match "^\d+$" -and [int]$ans -ge 1 -and [int]$ans -le $CUDA_TABLE.Count) { $chosen = $CUDA_TABLE[[int]$ans - 1].Key }
    else { Die "无效输入: $ans" }
}

if ($chosen -eq "cpu") {
    $torchIndex = "https://download.pytorch.org/whl/cpu"; $chosenLabel = "CPU"
} else {
    $c = $CUDA_TABLE | Where-Object Key -eq $chosen
    if (-not $c) { Die "未知后端: $chosen" }
    if ($gpuName -and $driverVer) {
        $maj = 0; if ($driverVer -match "^(\d+)") { $maj = [int]$Matches[1] }
        if ($maj -lt $c.MinDriver) {
            Warn2 ("驱动 $driverVer 低于 " + $c.Name + " 的建议值 " + $c.MinDriver + "，装完可能 cuda 不可用")
            $go = Read-Host "    继续？(y/N)"
            if ($go -notmatch "^[Yy]") { Die "已取消" }
        }
    }
    $torchIndex = $c.Index; $chosenLabel = $c.Name
}
Ok "后端: $chosenLabel"

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

$pipCommon = @("--prefer-binary", "--timeout", "60", "--retries", "3", "--no-input")

if ($SkipDeps) {
    Warn2 "已指定 -SkipDeps：跳过所有 pip 安装"
} else {
    if ($UpgradePip) {
        Step "升级 pip（可选步骤，若网络慢可跳过）"
        & $venvPy -m pip install --upgrade pip --timeout 60 --retries 2 -q
        if ($LASTEXITCODE -ne 0) { Warn2 "pip 升级失败，继续用现有版本" }
        else { Ok ("pip " + (& $venvPy -m pip --version).Split(" ")[1]) }
    }

    # ------------------------------------------------------------ 5. torch
    Step "安装 PyTorch（$chosenLabel）"
    $curVer = ""
    try { $curVer = (& $venvPy -c "import torch;print(torch.__version__)" 2>$null | Select-Object -First 1) } catch { }
    if ($curVer) { Write-Host "    当前: torch $curVer" -ForegroundColor DarkGray }

    $wantCuda = ($chosen -ne "cpu")
    $same = ($wantCuda -and $curVer -match ("\+" + $chosen)) -or ((-not $wantCuda) -and $curVer -match "\+cpu")

    if ($same -and -not $Force) {
        Ok "已是 $chosenLabel 版本，跳过（要重装加 -Force）"
    } else {
        Write-Host "    从 $torchIndex 下载，耐心等待…" -ForegroundColor DarkGray
        & $venvPy -m pip install @pipCommon torch torchvision --index-url $torchIndex
        if ($LASTEXITCODE -ne 0) {
            Die "PyTorch 安装失败。可尝试：换 -Backend cu124 / 加 -Mirror / 检查 download.pytorch.org 是否可达"
        }
        Ok "PyTorch 安装完成"
    }

    # ------------------------------------------------------------ 6. 其它依赖
    Step "安装 ultralytics / flask / opencv"
    $depArgs = @("install") + $pipCommon + @("-r", (Join-Path $PSScriptRoot "requirements.txt"))
    if ($Mirror) { $depArgs += @("-i", $MIRROR_URL) }
    & $venvPy -m pip @depArgs
    if ($LASTEXITCODE -ne 0 -and -not $Mirror) {
        Warn2 "直连 PyPI 失败，改用清华镜像重试…"
        $depArgs += @("-i", $MIRROR_URL)
        & $venvPy -m pip @depArgs
    }
    if ($LASTEXITCODE -ne 0) { Die "依赖安装失败" }
    Ok "依赖就绪"
}

# ---------------------------------------------------------------- 7. 自检
Step "运行时自检"
$rc = & $venvPy -c @"
import torch
print('torch        :', torch.__version__)
print('cuda 可用    :', torch.cuda.is_available())
if torch.cuda.is_available():
    print('GPU          :', torch.cuda.get_device_name(0))
    print('显存         :', round(torch.cuda.get_device_properties(0).total_memory/1024**3, 1), 'GB')
    print('CUDA runtime :', torch.version.cuda)
try:
    import ultralytics, flask, cv2
    print('ultralytics  :', ultralytics.__version__)
except Exception as e:
    print('缺依赖       :', e)
"@ 2>&1
$rc | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }

$wantCuda = ($chosen -ne "cpu")
if ($wantCuda -and ($rc -join "`n") -notmatch "cuda 可用\s*:\s*True") {
    Warn2 "选的是 GPU 版，但检测不到可用 CUDA —— 常见原因：驱动太旧 / 显卡不支持 / 装成了 CPU 版"
    Warn2 "先用 CPU 版验证功能：-Backend cpu"
} elseif ($wantCuda) { Ok "GPU 加速可用" }

# ---------------------------------------------------------------- 8. 模型
Step "检查模型权重"
$modelDir = Join-Path $PSScriptRoot "models"
$need = @{
    "solder_yolo26m_800.onnx" = "焊接缺陷 9 类 (imgsz 800)"
    "bare_yolo26s_1024.onnx"  = "裸板缺陷 7 类 (imgsz 1024)"
}
foreach ($f in $need.Keys) {
    $fp = Join-Path $modelDir $f
    if (Test-Path $fp) { Ok ("{0}  ({1} MB)  {2}" -f $f, [math]::Round((Get-Item $fp).Length / 1MB, 1), $need[$f]) }
    else { Warn2 "缺少 $f  —— $($need[$f])，见 models\README.md" }
}

# ---------------------------------------------------------------- 9. 启动
if ($NoStart) {
    Write-Host "`n安装完成。" -ForegroundColor Green
    Write-Host "启动：`n  $venvPy app_flask.py" -ForegroundColor White
    Write-Host "或双击 start.bat" -ForegroundColor White
    exit 0
}

Write-Host "`n安装完成，正在启动服务…（Ctrl+C 停止）`n" -ForegroundColor Green
$env:YOLO_CONFIG_DIR = Join-Path $PSScriptRoot ".ultralytics"
$env:PYTHONUTF8 = "1"
& $venvPy app_flask.py