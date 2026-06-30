#!/bin/bash
set -e

# 인자 수신
MODE="$1"
HEF="$2"
IMAGE="$3"
LABEL="$4"
FRAMES="$5"
BATCH="$6"
PRIORITY="$7"
TIMEOUT="$8"
THRESHOLD="$9"
LOG_FILE="${10}"

EXECUTABLE="./build/multi_process"

if [ ! -f "$EXECUTABLE" ]; then
    echo "Error: Executable not found at $EXECUTABLE"
    exit 1
fi

# 실행 커맨드 구성
CMD=("$EXECUTABLE" "$HEF" "$IMAGE" "$LABEL" "$FRAMES" "$BATCH" "$PRIORITY" "$TIMEOUT" "$THRESHOLD")

case "$MODE" in
    default)
        "${CMD[@]}" > "$LOG_FILE" 2>&1 &
        ;;
    log)
        HAILORT_LOG_DIR="${LOG_FILE%.*}_hailort"
        mkdir -p "$HAILORT_LOG_DIR"
        export HAILORT_CONSOLE_LOGGER_LEVEL=info
        export HAILORT_LOGGER_PATH="$HAILORT_LOG_DIR"
        "${CMD[@]}" > "$LOG_FILE" 2>&1 &
        ;;
    *)
        echo "Unknown mode: $MODE"
        exit 1
        ;;
esac

PID=$!
echo "   -> Started PID=$PID (log: $LOG_FILE)"