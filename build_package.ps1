[CmdletBinding()]
param(
    [string]$OutputDir = "dist",
    [string]$PackageName = "",
    [string]$PythonExe = ""
)

$ErrorActionPreference = "Stop"

function Test-LocalPythonCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Executable,
        [string[]]$Arguments = @()
    )

    try {
        & $Executable @Arguments -c "import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)" *> $null
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Resolve-LocalPythonCommand {
    param([string]$RequestedExecutable = "")

    $Candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($RequestedExecutable)) {
        $Candidates += [pscustomobject]@{ Name = $RequestedExecutable; Arguments = @() }
    } else {
        if (-not [string]::IsNullOrWhiteSpace($env:PYTHON)) {
            $Candidates += [pscustomobject]@{ Name = $env:PYTHON; Arguments = @() }
        }
        $Candidates += [pscustomobject]@{ Name = "python"; Arguments = @() }
        $Candidates += [pscustomobject]@{ Name = "python3"; Arguments = @() }
        $Candidates += [pscustomobject]@{ Name = "py"; Arguments = @("-3") }
    }

    foreach ($Candidate in $Candidates) {
        $Command = Get-Command -Name $Candidate.Name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($null -eq $Command) { continue }
        if (Test-LocalPythonCommand -Executable $Command.Source -Arguments $Candidate.Arguments) {
            return [pscustomobject]@{
                Executable = $Command.Source
                Arguments = @($Candidate.Arguments)
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($RequestedExecutable)) {
        throw "The requested local Python is missing or unusable: $RequestedExecutable"
    }
    throw "No usable local Python 3.8+ was found. Install Python, set the PYTHON environment variable, or pass -PythonExe."
}

function New-PortableZipArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $SourcePrefix = [System.IO.Path]::GetFullPath($SourceRoot)
    $Archive = [System.IO.Compression.ZipFile]::Open(
        $DestinationPath,
        [System.IO.Compression.ZipArchiveMode]::Create
    )
    try {
        Get-ChildItem -LiteralPath $SourceRoot -File -Recurse |
            Sort-Object FullName |
            ForEach-Object {
                $RelativePath = $_.FullName.Substring($SourcePrefix.Length).TrimStart('\', '/')
                $EntryName = $RelativePath.Replace('\', '/')
                $Entry = $Archive.CreateEntry(
                    $EntryName,
                    [System.IO.Compression.CompressionLevel]::Optimal
                )
                $InputStream = $_.OpenRead()
                $OutputStream = $Entry.Open()
                try {
                    $InputStream.CopyTo($OutputStream)
                } finally {
                    $OutputStream.Dispose()
                    $InputStream.Dispose()
                }
            }
    } finally {
        $Archive.Dispose()
    }
}

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
    "README.md",
    "VERSION",
    "CHANGELOG.md",
    "release_manifest.json",
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
    "runtime\python",
    "tools"
)

$PortablePythonDir = Join-Path $ProjectRoot "runtime\python\windows-x64"
$PortablePythonExe = Join-Path $PortablePythonDir "python.exe"
$PortablePythonwExe = Join-Path $PortablePythonDir "pythonw.exe"
$PortablePythonStdlib = Join-Path $PortablePythonDir "python38.zip"
$PortablePythonPathFile = Join-Path $PortablePythonDir "python38._pth"
$PortablePythonLicense = Join-Path $PortablePythonDir "LICENSE.txt"

foreach ($RequiredRuntimeFile in @($PortablePythonExe, $PortablePythonwExe, $PortablePythonStdlib, $PortablePythonPathFile, $PortablePythonLicense)) {
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
$PythonPathEntries = Get-Content -LiteralPath $PortablePythonPathFile |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith("#") }
if ($PythonPathEntries -notcontains "python38") {
    throw "Portable Python path configuration must include the unpacked python38 directory: $PortablePythonPathFile"
}

$RuntimeSelfTest = Join-Path $ProjectRoot "modules\local_mesh_optimizer\python\runtime_self_test.py"
$LocalPython = Resolve-LocalPythonCommand -RequestedExecutable $PythonExe
$LocalPythonArgs = @($LocalPython.Arguments)
Write-Host "Using local Python for package self-test: $($LocalPython.Executable) $($LocalPythonArgs -join ' ')"
& $LocalPython.Executable @LocalPythonArgs $RuntimeSelfTest
if ($LASTEXITCODE -ne 0) {
    throw "Local Python runtime self-test failed with exit code $LASTEXITCODE."
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
            Where-Object {
                $_.Extension -ieq ".fem" -or
                $_.Name -ilike "*_manifest.json"
            } |
            Remove-Item -Force
    }
    $PackagedCommandCapture = Join-Path $TempProjectRoot "doc\command.tcl"
    if (Test-Path -LiteralPath $PackagedCommandCapture) {
        Remove-Item -LiteralPath $PackagedCommandCapture -Force
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
    $StagedUnpackedStdlib = Join-Path $StagedPythonDir "python38"
    if (Test-Path -LiteralPath $StagedUnpackedStdlib) {
        Remove-Item -LiteralPath $StagedUnpackedStdlib -Recurse -Force
    }
    foreach ($RequiredName in @("python.exe", "pythonw.exe", "python38.zip", "python38._pth", "LICENSE.txt")) {
        $StagedFile = Join-Path $StagedPythonDir $RequiredName
        if (-not (Test-Path -LiteralPath $StagedFile -PathType Leaf)) {
            throw "Staged package is missing portable Python file: $StagedFile"
        }
    }

    $ManifestScript = Join-Path $ProjectRoot "tools\build_release_manifest.py"
    $StagedManifest = Join-Path $TempProjectRoot "release_manifest.json"
    & $LocalPython.Executable @LocalPythonArgs $ManifestScript --source-root $ProjectRoot --output $StagedManifest
    if ($LASTEXITCODE -ne 0) {
        throw "Release manifest generation failed with exit code $LASTEXITCODE."
    }

    New-PortableZipArchive -SourceRoot $TempRoot -DestinationPath $ZipPath
    $AuditScript = Join-Path $ProjectRoot "tools\release_audit.py"
    & $LocalPython.Executable @LocalPythonArgs $AuditScript --zip $ZipPath
    if ($LASTEXITCODE -ne 0) {
        throw "Release audit failed with exit code $LASTEXITCODE."
    }
    Write-Host "Package created: $ZipPath"
} finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force
    }
}
