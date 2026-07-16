#!/bin/bash
set -e

BUILD_DIR="./build"
TARGET="inference_driver"

echo "============================================"
echo " Configuring project with CMake"
echo "============================================"
cmake -S . -B "$BUILD_DIR"

echo "============================================"
echo " Building $TARGET in $BUILD_DIR"
echo "============================================"
cmake --build "$BUILD_DIR" --target "$TARGET"

echo "Build finished successfully."
