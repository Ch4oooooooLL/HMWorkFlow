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
    "使用教程.pdf",
    "config.yaml",
    "guide.html",
    "install_update.tcl",
    "hw_toolkit.tcl",
    "hw_toolkit_core.tcl",
    "shortcut_bootstrap.tcl",
    "build_package.ps1",
    "build_package.sh",
    "config",
    "doc",
    "examples",
    "modules",
    "runtime"
)

$PortablePythonDir = Join-Path $ProjectRoot "runtime\python\windows-x64"
$PortablePythonExe = Join-Path $PortablePythonDir "python.exe"
$PortablePythonwExe = Join-Path $PortablePythonDir "pythonw.exe"
$PortablePythonStdlib = Join-Path $PortablePythonDir "python38.zip"
$PortablePythonLicense = Join-Path $PortablePythonDir "LICENSE.txt"

foreach ($RequiredRuntimeFile in @($PortablePythonExe, $PortablePythonwExe, $PortablePythonStdlib, $PortablePythonLicense)) {
    if (-not (Test-Path -LiteralPath $RequiredRuntimeFile -PathType Leaf)) {
        throw "Portable Python runtime is incomplete. Missing: $RequiredRuntimeFile. See runtime/python/README.md."
    }
}

$ExpectedPythonExeSha256 = "5275c42f7359fa2c7ec473be3240e57d5ce5b9301a26bd2e98e89bb9db074581"
$ExpectedPythonwExeSha256 = "a409db42d754c311d19921fbbf458c1abadc5142330cdb7f3c6016e97fa1116d"
$ExpectedPythonStdlibSha256 = "613e0d63b54ed995273eda446eb09e51066e486f1e72b94f1c338a83dca3a021"
if ((Get-FileHash -LiteralPath $PortablePythonExe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedPythonExeSha256) {
    throw "Portable Python executable checksum mismatch: $PortablePythonExe"
}
if ((Get-FileHash -LiteralPath $PortablePythonwExe -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedPythonwExeSha256) {
    throw "Portable windowless Python executable checksum mismatch: $PortablePythonwExe"
}
if ((Get-FileHash -LiteralPath $PortablePythonStdlib -Algorithm SHA256).Hash.ToLowerInvariant() -ne $ExpectedPythonStdlibSha256) {
    throw "Portable Python standard-library checksum mismatch: $PortablePythonStdlib"
}

$RuntimeSelfTest = Join-Path $ProjectRoot "modules\local_mesh_optimizer\python\runtime_self_test.py"
& $PortablePythonExe $RuntimeSelfTest
if ($LASTEXITCODE -ne 0) {
    throw "Bundled Python runtime self-test failed with exit code $LASTEXITCODE."
}

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
    # Example generators and documentation are distributable source assets,
    # while generated solver models are large reproducible outputs.
    $PackagedExamplesDir = Join-Path $TempProjectRoot "examples"
    if (Test-Path -LiteralPath $PackagedExamplesDir) {
        Get-ChildItem -LiteralPath $PackagedExamplesDir -File -Recurse |
            Where-Object { $_.Extension -ieq ".fem" } |
            Remove-Item -Force
    }
    Get-ChildItem -LiteralPath $TempProjectRoot -Directory -Recurse -Filter "__pycache__" |
        Remove-Item -Recurse -Force
    # `-Include` is unreliable with a literal directory path and can yield all
    # files on Windows PowerShell 5.1, which previously emptied the staged
    # package. Filter the enumerated files by extension explicitly.
    Get-ChildItem -LiteralPath $TempProjectRoot -File -Recurse |
        Where-Object { $_.Extension -in @(".pyc", ".pyo") } |
        Remove-Item -Force

    $StagedPythonDir = Join-Path $TempProjectRoot "runtime\python\windows-x64"
    foreach ($RequiredName in @("python.exe", "pythonw.exe", "python38.zip", "LICENSE.txt")) {
        $StagedFile = Join-Path $StagedPythonDir $RequiredName
        if (-not (Test-Path -LiteralPath $StagedFile -PathType Leaf)) {
            throw "Staged package is missing portable Python file: $StagedFile"
        }
    }

    Compress-Archive -Path $TempProjectRoot -DestinationPath $ZipPath -CompressionLevel Optimal -Force
    Write-Host "Package created: $ZipPath"
} finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
