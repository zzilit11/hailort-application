#!/bin/bash

set -e

# ======================================================================
# 빌드
# ======================================================================
if [ ! -d "./build" ]; then
    echo "Error: build directory './build' not found."
    echo "Please run cmake and create build directory first."
    exit 1
fi

echo "============================================"
echo " Building project in ./build"
echo "============================================"
(
    cd ./build
    make
)