#!/bin/bash

set -e

# ======================================================================
# 모드 선택, frame count 설정
# ======================================================================
MODE="$1"
FRAME_COUNT="$2"
BATCH_SIZE="$3"

case "$MODE" in
    default)
        echo "Run mode: DEFAULT"
        ;;
    log)
        echo "Run mode: LOG (LD_PRELOAD=libloghailort.so)"
        ;;
    *)
        echo "Invalid mode: $MODE"
        echo "Choose: default | log"
        exit 1
        ;;
esac

if [ -z "$FRAME_COUNT" ]; then
    FRAME_COUNT=1000
fi

if [ -z "$BATCH_SIZE" ]; then
    BATCH_SIZE=10
fi

# ======================================================================
# 설정 영역
# ======================================================================

readonly EXECUTABLE="./build/multi_process"

# 4: ResNet152
HEFS[0]="/home/hailo/models/resnet152_v1.hef"
IMAGES[0]="/home/hailo/images/_images_4.png"
LABELS[0]="/home/hailo/labels/imagenet_labels.json"
INSTANCES[0]=1


# ======================================================================
# 실행 로직
# ======================================================================

if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Executable not found at $EXECUTABLE"
    exit 1
fi

echo "============================================"
echo " Starting Multi-Process Inference Manager"
echo "============================================"

log_dir="./logs"
mkdir -p "$log_dir"

echo ">> Launching Job Set #1"
echo "   - Model: $(basename "${HEFS[0]}")"
echo "   - Image: ${IMAGES[0]}"
echo "   - Instances: ${INSTANCES[0]}"
echo "   - Mode: $MODE"
for (( i=1; i<=${INSTANCES[0]}; i++ )); do
    log_file="$log_dir/job_4_${i}.log"
    case "$MODE" in
        default)
            "$EXECUTABLE" \
                "${HEFS[0]}" "${IMAGES[0]}" "${LABELS[0]}" "$FRAME_COUNT" "$BATCH_SIZE" \
                > "$log_file" 2>&1 &
            ;;
        log)
            LD_PRELOAD=/usr/local/lib/libloghailort.so \
            "$EXECUTABLE" \
                "${HEFS[0]}" "${IMAGES[0]}" "${LABELS[0]}" "$FRAME_COUNT" "$BATCH_SIZE" \
                > "$log_file" 2>&1 &
            ;;
    esac
    pid=$!
    echo "   -> Started PID=$pid (log: $log_file)"
done
wait
