#!/bin/bash

# 에러 발생 시 즉시 중단
set -e

echo "Building the inference driver..."

# build 디렉토리로 이동
if [ ! -d "./build" ]; then
    echo "ERROR: 'build' directory not found."
    exit 1
fi

cd ./build
make

echo "Build finished successfully."