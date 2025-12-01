#!/bin/bash

# Exit on any failure
set -e 

# Build the inference driver
cd ./build
make

# ------------- Configuration -------------
executable="./inference_driver"
model="/home/hailo/hailo_models/resnet50_v1.hef"
image_dir="/home/hailo/images"
class_labels="/home/hailo/labels/imagenet_labels.json"
# -----------------------------------------

# Select mode: default | log
MODE="$1"     # 인자로 모드 선택: ./run.sh default  또는 ./run.sh log

if [ -z "$MODE" ]; then
    echo "Usage: $0 [default | log]"
    exit 1
fi

# Sanity check for files and directories
if [ ! -f "$model" ]; then
    echo "ERROR: Model file not found: $model"
    exit 1
fi

if [ ! -d "$image_dir" ]; then
    echo "ERROR: Image directory not found: $image_dir"
    exit 1
fi

echo "Starting inference in ${MODE^^} mode..."

case "$MODE" in
    default)
        "$executable" "$model" "$image_dir" "$class_labels"
        ;;
    log)
        LD_PRELOAD=/usr/local/lib/libloghailort.so LD_DEBUG=libs \
        "$executable" "$model" "$image_dir" "$class_labels" 2>&1 | grep -E 'hailort|loghailort'
        ;;
    *)
        echo "Invalid mode: $MODE"
        echo "Choose: default | log"
        exit 1
        ;;
esac

cd ..
echo "Inference finished"
