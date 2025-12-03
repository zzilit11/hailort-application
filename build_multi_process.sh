#!/bin/bash

BUILD_DIR="./build"

echo "============================================"
echo " Configuring project with CMake"
echo "============================================"
cmake -S . -B "$BUILD_DIR"

echo "============================================"
echo " Building project in $BUILD_DIR"
echo "============================================"
cmake --build "$BUILD_DIR"