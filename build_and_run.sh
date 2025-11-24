#!/bin/bash

# Exit on any failure
set -e 

# Build the inference driver
cd ./build
make

# ------------- Configuration -------------
executable="./inference_driver"
model="/home/rtoslab-alpha/workspace/hailort/resnet_v1_50.hef"
image_dir="/home/rtoslab-alpha/workspace/hailort/images"
class_labels="/home/rtoslab-alpha/workspace/hailort/resnet50_class_labels.json"
# -----------------------------------------

# Sanity check for files and directories
if [ ! -f "$model" ]; then
    echo "ERROR: Model file not found: $model"
    exit 1
fi

if [ ! -d "$image_dir" ]; then
    echo "ERROR: Image directory not found: $image_dir"
    exit 1
fi

echo "Starting inference..."
"$executable" "$model" "$image_dir" "$class_labels"
cd ..
echo "Inference finished"