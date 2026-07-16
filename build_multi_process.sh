#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
TARGET="multi_process"

echo "============================================"
echo " Configuring project with CMake"
echo "============================================"
cmake -S "${SCRIPT_DIR}" -B "$BUILD_DIR"

echo "============================================"
echo " Building $TARGET in $BUILD_DIR"
echo "============================================"
cmake --build "$BUILD_DIR" --target "$TARGET"

echo "Build finished successfully."
