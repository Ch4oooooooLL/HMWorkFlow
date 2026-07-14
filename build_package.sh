#!/usr/bin/env bash
#
# build_package.sh - Linux equivalent of build_package.ps1
# Packages the HM WorkFlow project into a .zip archive.
#
# Usage:
#   ./build_package.sh [--output-dir <dir>] [--package-name <name>]
#
# Options:
#   --output-dir   Output directory (default: dist)
#   --package-name Package name (default: <ProjectName>_<timestamp>.zip)
#   -h, --help     Show this help message

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OUTPUT_DIR="dist"
PACKAGE_NAME=""

# ---------------------------------------------------------------------------
# Helper: print usage and exit
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Usage: ./build_package.sh [--output-dir <dir>] [--package-name <name>]

Options:
  --output-dir   Output directory (default: dist)
  --package-name Package name (default: <ProjectName>_<timestamp>.zip)
  -h, --help     Show this help message
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Helper: resolve an absolute path from a possibly-relative one
# ---------------------------------------------------------------------------
resolve_path() {
    local path="$1"
    if [[ "$path" = /* ]]; then
        echo "$path"
    else
        echo "${PROJECT_ROOT}/${path}"
    fi
}

# ---------------------------------------------------------------------------
# Parse command-line arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --package-name)
            PACKAGE_NAME="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1" >&2
            echo "Usage: $0 [--output-dir <dir>] [--package-name <name>]" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Determine project root (directory containing this script)
# ---------------------------------------------------------------------------
PROJECT_ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PROJECT_NAME="$(basename "$PROJECT_ROOT")"

# ---------------------------------------------------------------------------
# Resolve output directory and ensure it exists
# ---------------------------------------------------------------------------
RESOLVED_OUTPUT_DIR="$(resolve_path "$OUTPUT_DIR")"
mkdir -p "$RESOLVED_OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Generate package name if not supplied
# ---------------------------------------------------------------------------
if [[ -z "$PACKAGE_NAME" ]]; then
    TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
    PACKAGE_NAME="${PROJECT_NAME}_${TIMESTAMP}.zip"
elif [[ ! "$PACKAGE_NAME" =~ \.[Zz][Ii][Pp]$ ]]; then
    PACKAGE_NAME="${PACKAGE_NAME}.zip"
fi

# ---------------------------------------------------------------------------
# Full path to the output zip file
# ---------------------------------------------------------------------------
ZIP_PATH="${RESOLVED_OUTPUT_DIR}/${PACKAGE_NAME}"
if [[ -f "$ZIP_PATH" ]]; then
    rm -f "$ZIP_PATH"
fi

# ---------------------------------------------------------------------------
# Items to include in the package
# ---------------------------------------------------------------------------
INCLUDE_ITEMS=(
    ".editorconfig"
    ".gitignore"
    "README.md"
    "README_LocalMeshOptimizer.md"
    "INTEGRATION_ANALYSIS.md"
    "使用教程.pdf"
    "config.yaml"
    "guide.html"
    "install_update.tcl"
    "hw_toolkit.tcl"
    "hw_toolkit_core.tcl"
    "shortcut_bootstrap.tcl"
    "build_package.ps1"
    "build_package.sh"
    "config"
    "doc"
    "examples"
    "modules"
    "runtime"
)

PORTABLE_PYTHON_DIR="${PROJECT_ROOT}/runtime/python/windows-x64"
PORTABLE_PYTHON_EXE="${PORTABLE_PYTHON_DIR}/python.exe"
PORTABLE_PYTHONW_EXE="${PORTABLE_PYTHON_DIR}/pythonw.exe"
PORTABLE_PYTHON_ZIP="${PORTABLE_PYTHON_DIR}/python38.zip"
PORTABLE_PYTHON_SHA256="abbe314e9b41603dde0a823b76f5bbbe17b3de3e5ac4ef06b759da5466711271"
PORTABLE_PYTHON_EXE_SHA256="5275c42f7359fa2c7ec473be3240e57d5ce5b9301a26bd2e98e89bb9db074581"
PORTABLE_PYTHONW_EXE_SHA256="a409db42d754c311d19921fbbf458c1abadc5142330cdb7f3c6016e97fa1116d"
PORTABLE_PYTHON_STDLIB_SHA256="613e0d63b54ed995273eda446eb09e51066e486f1e72b94f1c338a83dca3a021"

if [[ ! -f "$PORTABLE_PYTHON_EXE" || ! -f "$PORTABLE_PYTHONW_EXE" || ! -f "$PORTABLE_PYTHON_ZIP" ]]; then
    echo "Portable Python runtime is incomplete: ${PORTABLE_PYTHON_DIR}" >&2
    echo "Expected python.exe, pythonw.exe and python38.zip. See runtime/python/README.md." >&2
    exit 1
fi

actual_exe_sha256="$(sha256sum "$PORTABLE_PYTHON_EXE" | awk '{print $1}')"
actual_pythonw_sha256="$(sha256sum "$PORTABLE_PYTHONW_EXE" | awk '{print $1}')"
actual_stdlib_sha256="$(sha256sum "$PORTABLE_PYTHON_ZIP" | awk '{print $1}')"
if [[ "$actual_exe_sha256" != "$PORTABLE_PYTHON_EXE_SHA256" ||
      "$actual_pythonw_sha256" != "$PORTABLE_PYTHONW_EXE_SHA256" ||
      "$actual_stdlib_sha256" != "$PORTABLE_PYTHON_STDLIB_SHA256" ]]; then
    echo "Portable Python runtime checksum mismatch." >&2
    exit 1
fi

python3 "${PROJECT_ROOT}/modules/local_mesh_optimizer/python/runtime_self_test.py"

if [[ -f "${PROJECT_ROOT}/runtime/python/python-3.8.10-embed-amd64.zip" ]]; then
    actual_sha256="$(sha256sum "${PROJECT_ROOT}/runtime/python/python-3.8.10-embed-amd64.zip" | awk '{print $1}')"
    if [[ "$actual_sha256" != "$PORTABLE_PYTHON_SHA256" ]]; then
        echo "Portable Python source archive checksum mismatch." >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Create a unique temp directory and build the package structure there
# ---------------------------------------------------------------------------
TEMP_ROOT="$(mktemp -d -t "${PROJECT_NAME}_package_XXXXXXXXXX")"
TEMP_PROJECT_ROOT="${TEMP_ROOT}/${PROJECT_NAME}"

cleanup() {
    if [[ -d "$TEMP_ROOT" ]]; then
        rm -rf "$TEMP_ROOT"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Copy items into the temp staging area
# ---------------------------------------------------------------------------
mkdir -p "$TEMP_PROJECT_ROOT"

for item in "${INCLUDE_ITEMS[@]}"; do
    src="${PROJECT_ROOT}/${item}"
    if [[ ! -e "$src" ]]; then
        continue
    fi

    dest="${TEMP_PROJECT_ROOT}/${item}"
    dest_parent="$(dirname "$dest")"
    mkdir -p "$dest_parent"

    cp -a "$src" "$dest"
done

# ---------------------------------------------------------------------------
# Remove *_state.txt files from the packaged config/ directory
# ---------------------------------------------------------------------------
PACKAGED_CONFIG_DIR="${TEMP_PROJECT_ROOT}/config"
if [[ -d "$PACKAGED_CONFIG_DIR" ]]; then
    find "$PACKAGED_CONFIG_DIR" -maxdepth 1 -type f -name '*_state.txt' -delete
fi
find "$TEMP_PROJECT_ROOT" -type d -name '__pycache__' -prune -exec rm -rf {} +
find "$TEMP_PROJECT_ROOT" -type f \( -name '*.pyc' -o -name '*.pyo' \) -delete

if [[ ! -f "${TEMP_PROJECT_ROOT}/runtime/python/windows-x64/python.exe" ||
      ! -f "${TEMP_PROJECT_ROOT}/runtime/python/windows-x64/pythonw.exe" ||
      ! -f "${TEMP_PROJECT_ROOT}/runtime/python/windows-x64/python38.zip" ||
      ! -f "${TEMP_PROJECT_ROOT}/runtime/python/windows-x64/LICENSE.txt" ]]; then
    echo "Staged package is missing the portable Python runtime or license." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Helper: create a zip archive. Tries the system `zip` first; falls back to
# Python's built-in zipfile module (which is always available).
# Usage: create_zip <source_dir> <output_zip_path> <base_name>
# ---------------------------------------------------------------------------
create_zip() {
    local src_dir="$1"
    local zip_path="$2"
    local base_name="$3"

    if command -v zip &>/dev/null; then
        (cd "$src_dir" && zip -rq "$zip_path" "$base_name")
    else
        PY_SRC_DIR="$src_dir" PY_ZIP_PATH="$zip_path" PY_BASE_NAME="$base_name" python3 -c '
import zipfile, os
src_dir = os.environ["PY_SRC_DIR"]
zip_path = os.environ["PY_ZIP_PATH"]
base_name = os.environ["PY_BASE_NAME"]
os.chdir(src_dir)
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
    for root, dirs, files in os.walk(base_name):
        for fn in files:
            fp = os.path.join(root, fn)
            zf.write(fp, fp)
'
    fi
}

# ---------------------------------------------------------------------------
# Create the zip archive
# ---------------------------------------------------------------------------
create_zip "$TEMP_ROOT" "$ZIP_PATH" "$PROJECT_NAME"

echo "Package created: ${ZIP_PATH}"
