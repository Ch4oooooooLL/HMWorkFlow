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
    "使用教程.pdf"
    "config.yaml"
    "hw_toolkit.tcl"
    "hw_toolkit_core.tcl"
    "shortcut_bootstrap.tcl"
    "build_package.ps1"
    "build_package.sh"
    "config"
    "doc"
    "modules"
)

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
