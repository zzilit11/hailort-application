#!/bin/bash

# ------------- Configuration -------------
executable="/home/taespberry/WORKSPACE/hailort-application/build/inference_driver"
model="/home/taespberry/WORKSPACE/official_models/resnet_v1_50.hef"
#model="/home/taespberry/WORKSPACE/official_models/resnet_v1_50.hef"
#model="/home/taespberry/WORKSPACE/official_models/vit_base.hef"
image_dir="/home/taespberry/WORKSPACE/images"
class_labels="/home/taespberry/WORKSPACE/labels/imagenet_labels.json"
# -----------------------------------------

# Sanity check for files and directories
if [ ! -f "$executable" ]; then
    echo "ERROR: Executable not found at: $executable"
    echo "Please run './build_inference.sh' first."
    exit 1
fi

if [ ! -f "$model" ]; then
    echo "ERROR: Model file not found: $model"
    exit 1
fi

if [ ! -d "$image_dir" ]; then
    echo "ERROR: Image directory not found: $image_dir"
    exit 1
fi

# ---------------------------------------------------------
# Change Working Directory
# executable이 있는 build 디렉토리의 상위 디렉토리로 이동
# ---------------------------------------------------------
BUILD_DIR=$(dirname "$executable")
WORK_DIR="$BUILD_DIR/.."

# 디렉토리 이동 시도
if ! cd "$WORK_DIR"; then
    echo "ERROR: Failed to change directory to $WORK_DIR"
    exit 1
fi

echo "Current working directory: $(pwd)"
echo "Starting inference..."

"$executable" "$model" "$image_dir" "$class_labels"

echo "Inference finished"