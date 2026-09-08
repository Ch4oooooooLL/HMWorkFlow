# ======================================================================
# launch_cli.ps1 — 启动 HMWorkFlow 模型生成 CLI (tools/model_generation/model_cli.py)
#
# 解释器选择（自动）：
#   1) --Python <path> 显式指定；
#   2) 系统 python（优先：能 import cadquery 的，STEP 生成器需要 OCCT）；
#   3) 便携 Python 运行时 runtime/python/windows-x64/python.exe
#      （CLI 的 auto 策略会把 15 个 FEM 生成器交给便携 Python 3.8，
#       4 个 STEP 生成器交给启动 CLI 的解释器）；
#   4) 以上皆无则报错退出。
#
# 用法（示例）：
#   powershell -ExecutionPolicy Bypass -File tools\model_generation\launch_cli.ps1
#   .\tools\model_generation\launch_cli.ps1 -List
#   .\tools\model_generation\launch_cli.ps1 -All -Yes
#   .\tools\model_generation\launch_cli.ps1 -Only gen_temp_nodes,gen_midsurf
#   .\tools\model_generation\launch_cli.ps1 -All -Outdir D:\models
#   .\tools\model_generation\launch_cli.ps1 -All -Runner system
# ======================================================================

[CmdletBinding()]
param(
    [switch]$All,                # 生成全部模型
    [string[]]$Only,             # 只生成指定模型（脚本名/输出目录名，逗号或空格分隔）
    [switch]$List,               # 列出全部生成器后退出
    [string]$Runner = "auto",    # auto | portable | system
    [string]$Python,             # 强制指定解释器
    [string]$Outdir,             # 输出根目录（默认 tools/generated_models/）
    [switch]$Yes                 # 跳过 --all 确认
)

$ErrorActionPreference = "Stop"

# ---- UTF-8 控制台（中文显示） -----------------------------------------
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    [Console]::InputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$ScriptDir   = $PSScriptRoot
$RepoRoot    = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path
$CliScript   = Join-Path $ScriptDir "model_cli.py"
$PortablePy  = Join-Path $RepoRoot "runtime\python\windows-x64\python.exe"
$PortablePy2 = Join-Path $RepoRoot "runtime\python\windows-x64\python38\python.exe"

function Test-Cadquery {
    param([string]$py)
    if (-not $py -or -not (Test-Path $py)) { return $false }
    try {
        & $py -c "import cadquery" 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch {
        return $false
    }
}

# ---- 解释器探测 ---------------------------------------------------------
$python = $null
$warnStep = $false

if ($Python) {
    $python = $Python
    if (-not (Test-Path $python)) {
        throw "指定的 Python 不存在: $python"
    }
} else {
    $sysPy = $null
    try { $sysPy = (Get-Command python -ErrorAction SilentlyContinue).Source } catch { }
    $portable = $null
    if (Test-Path $PortablePy)  { $portable = $PortablePy }
    elseif (Test-Path $PortablePy2) { $portable = $PortablePy2 }

    if ($sysPy -and (Test-Cadquery $sysPy)) {
        # 系统 python 带 cadquery：STEP 生成器可用（FEM 交给 CLI 的 auto 策略用便携）
        $python = $sysPy
    }
    elseif ($portable) {
        # 只有便携运行时：FEM 可用，STEP 需要 cadquery 会失败（CLI 会明确报错）
        $python = $portable
        $warnStep = $true
    }
    elseif ($sysPy) {
        $python = $sysPy
        $warnStep = $true
    }
    else {
        throw "未找到 Python。请安装 Python（含 cadquery）或解压便携运行时到 runtime/python/windows-x64/。"
    }
}

if (-not (Test-Path $CliScript)) {
    throw "找不到 CLI 脚本: $CliScript"
}

Write-Host ""
Write-Host "  HMWorkFlow 模型生成 CLI" -ForegroundColor Cyan
Write-Host "  解释器 : $python" -ForegroundColor Gray
Write-Host "  CLI    : $CliScript" -ForegroundColor Gray
if ($warnStep) {
    Write-Host "  警告   : 当前解释器缺少 cadquery，STEP 生成器（midsurf/geom_cleanup/seam_surface/batch_mesher）将失败。" -ForegroundColor Yellow
    Write-Host "           请用 --Python 指定带 cadquery 的解释器（如系统 Python + pip install cadquery）。" -ForegroundColor Yellow
}
Write-Host ""

# ---- 透传参数给 CLI ------------------------------------------------------
$cliArgs = @()
if ($All)   { $cliArgs += "--all" }
if ($Only)  { $cliArgs += "--only";  $cliArgs += ($Only -join ",") }
if ($List)  { $cliArgs += "--list" }
if ($Runner -ne "auto") { $cliArgs += "--runner"; $cliArgs += $Runner }
if ($Outdir) { $cliArgs += "--outdir"; $cliArgs += $Outdir }
if ($Yes)   { $cliArgs += "--yes" }

& $python $CliScript @cliArgs
exit $LASTEXITCODE
