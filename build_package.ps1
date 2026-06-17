[CmdletBinding()]
param(
    [string]$OutputDir = "dist",
    [string]$PackageName = ""
)

$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectName = Split-Path -Leaf $ProjectRoot

if ([System.IO.Path]::IsPathRooted($OutputDir)) {
    $ResolvedOutputDir = $OutputDir
} else {
    $ResolvedOutputDir = Join-Path $ProjectRoot $OutputDir
}

if (-not (Test-Path -LiteralPath $ResolvedOutputDir)) {
    New-Item -ItemType Directory -Path $ResolvedOutputDir | Out-Null
}

if ([string]::IsNullOrWhiteSpace($PackageName)) {
    $Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $PackageName = "${ProjectName}_${Timestamp}.zip"
} elseif (-not $PackageName.EndsWith(".zip", [System.StringComparison]::OrdinalIgnoreCase)) {
    $PackageName = "$PackageName.zip"
}

$ZipPath = Join-Path $ResolvedOutputDir $PackageName
if (Test-Path -LiteralPath $ZipPath) {
    Remove-Item -LiteralPath $ZipPath -Force
}

$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}_package_{1}" -f $ProjectName, ([System.Guid]::NewGuid().ToString("N")))
$TempProjectRoot = Join-Path $TempRoot $ProjectName

$IncludeItems = @(
    ".editorconfig",
    ".gitignore",
    "README.md",
    "使用教程.pdf",
    "config.yaml",
    "hw_toolkit.tcl",
    "build_package.ps1",
    "config",
    "doc",
    "modules"
)

try {
    New-Item -ItemType Directory -Path $TempProjectRoot -Force | Out-Null

    foreach ($Item in $IncludeItems) {
        $Source = Join-Path $ProjectRoot $Item
        if (-not (Test-Path -LiteralPath $Source)) {
            continue
        }

        $Destination = Join-Path $TempProjectRoot $Item
        $DestinationParent = Split-Path -Parent $Destination
        if (-not (Test-Path -LiteralPath $DestinationParent)) {
            New-Item -ItemType Directory -Path $DestinationParent -Force | Out-Null
        }

        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
    }

    $PackagedConfigDir = Join-Path $TempProjectRoot "config"
    if (Test-Path -LiteralPath $PackagedConfigDir) {
        Get-ChildItem -LiteralPath $PackagedConfigDir -Filter "*_state.txt" -File |
            Remove-Item -Force
    }

    Compress-Archive -Path $TempProjectRoot -DestinationPath $ZipPath -CompressionLevel Optimal -Force
    Write-Host "Package created: $ZipPath"
} finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
