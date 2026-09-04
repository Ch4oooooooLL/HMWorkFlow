#requires -Version 5.1
<#
.SYNOPSIS
    Build the HMWorkFlow release package and upload it to AnyShare.

.DESCRIPTION
    Runs build_package.ps1, verifies that the expected ZIP was created, and
    then uploads it to "拷入 / 李永超 / HM" by using upload-anyshare.ps1.

.EXAMPLE
    .\build_and_upload.ps1

.EXAMPLE
    .\build_and_upload.ps1 -DryRun -ShowBrowser

.EXAMPLE
    .\build_and_upload.ps1 -PackageName HMWorkFlow_1.2.3.zip -Code RMCF
#>

[CmdletBinding()]
param(
    [string] $OutputDir = 'dist',

    [string] $PackageName = '',

    [string] $PythonExe = '',

    [string] $Folder = '李永超/HM',

    [string] $Link = 'https://pan.sntonly.com/anyshare/zh-cn/link/AA0C8639B7CC8F4108A086190C4ABCC545',

    [string] $Code = $env:ANYSHARE_CODE,

    [string] $UploadScript = 'C:\Users\hjlyc\Documents\Codex\2026-08-14\https-pan-sntonly-com-anyshare-zh\outputs\upload-anyshare.ps1',

    [switch] $ShowBrowser,

    [switch] $DryRun,

    [ValidateRange(1, 1440)]
    [int] $TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectName = Split-Path -Leaf $ProjectRoot
$BuildScript = Join-Path $ProjectRoot 'build_package.ps1'

if (-not (Test-Path -LiteralPath $BuildScript -PathType Leaf)) {
    throw "未找到打包脚本：$BuildScript"
}

if (-not (Test-Path -LiteralPath $UploadScript -PathType Leaf)) {
    throw "未找到 AnyShare 上传脚本：$UploadScript`n可通过 -UploadScript 指定脚本路径。"
}
$ResolvedUploadScript = (Resolve-Path -LiteralPath $UploadScript).Path

if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $ResolvedOutputDir = [System.IO.Path]::GetFullPath($OutputDir)
}
else {
    $ResolvedOutputDir = [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $OutputDir))
}

if ([string]::IsNullOrWhiteSpace($PackageName)) {
    $PackageName = '{0}_{1}.zip' -f $ProjectName, (Get-Date -Format 'yyyyMMdd_HHmmss')
}
elseif (-not $PackageName.EndsWith('.zip', [System.StringComparison]::OrdinalIgnoreCase)) {
    $PackageName = "$PackageName.zip"
}

if ([System.IO.Path]::GetFileName($PackageName) -ne $PackageName) {
    throw 'PackageName 只能是文件名，不能包含目录路径。请使用 -OutputDir 指定输出目录。'
}

$PackagePath = Join-Path $ResolvedOutputDir $PackageName
$DisplayFolder = ($Folder -split '[\\/]' | Where-Object { $_ }) -join ' / '
$BuildArguments = @{
    OutputDir = $ResolvedOutputDir
    PackageName = $PackageName
}
if (-not [string]::IsNullOrWhiteSpace($PythonExe)) {
    $BuildArguments.PythonExe = $PythonExe
}

Write-Host '[1/2] 正在打包并执行发布审计...'
& $BuildScript @BuildArguments

if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) {
    throw "打包脚本执行结束，但未找到预期产物：$PackagePath"
}
$ResolvedPackagePath = (Resolve-Path -LiteralPath $PackagePath).Path
$PackageInfo = Get-Item -LiteralPath $ResolvedPackagePath
Write-Host ('打包完成：{0} ({1:N2} MB)' -f $ResolvedPackagePath, ($PackageInfo.Length / 1MB))

$UploadArguments = @{
    Path = @($ResolvedPackagePath)
    Folder = $Folder
    Link = $Link
    TimeoutMinutes = $TimeoutMinutes
}
if (-not [string]::IsNullOrWhiteSpace($Code)) {
    $UploadArguments.Code = $Code
}
if ($ShowBrowser) {
    $UploadArguments.ShowBrowser = $true
}
if ($DryRun) {
    $UploadArguments.DryRun = $true
}

if ($DryRun) {
    Write-Host "[2/2] 正在验证 AnyShare 目标目录：拷入 / $DisplayFolder（不上传）..."
}
else {
    Write-Host "[2/2] 正在上传到 AnyShare：拷入 / $DisplayFolder ..."
}

& $ResolvedUploadScript @UploadArguments
if ($LASTEXITCODE -ne 0) {
    throw "AnyShare 上传脚本执行失败，退出码：$LASTEXITCODE"
}

if ($DryRun) {
    Write-Host "验证完成；文件未上传。打包产物保留在：$ResolvedPackagePath"
}
else {
    Write-Host "发布完成：$PackageName 已上传到 拷入 / $DisplayFolder"
}
