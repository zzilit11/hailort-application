#!/bin/bash

# ------------- Configuration -------------
executable="/home/taespberry/WORKSPACE/hailort-application/build/multi_process"
model="/home/taespberry/WORKSPACE/official_models/resnet_v1_50.hef"
#model="/home/taespberry/WORKSPACE/official_models/resnet_v1_50.hef"
#model="/home/taespberry/WORKSPACE/official_models/vit_base.hef"
image="/home/taespberry/WORKSPACE/images/_images_1.png"
class_labels="/home/taespberry/WORKSPACE/labels/imagenet_labels.json"
frame_count=200
batch_size=10
priority=16
timeout_ms=200
threshold=3
# -----------------------------------------

# Sanity check for files
if [ ! -f "$executable" ]; then
    echo "ERROR: Executable not found at: $executable"
    echo "Please run './build_inference.sh' first."
    exit 1
fi

if [ ! -f "$model" ]; then
    echo "ERROR: Model file not found: $model"
    exit 1
fi

if [ ! -f "$image" ]; then
    echo "ERROR: Image file not found: $image"
    exit 1
fi

if [ ! -f "$class_labels" ]; then
    echo "ERROR: Labels file not found: $class_labels"
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
echo "Starting multi-process inference..."

"$executable" "$model" "$image" "$class_labels" \
    "$frame_count" "$batch_size" "$priority" "$timeout_ms" "$threshold"

echo "Multi-process inference finished"
