#!/bin/bash
set -e

rm -rf logs
mkdir -p logs

MODE="$1"
FRAME_COUNT="$2"
BATCH_SIZE="$3"

if [ -z "$MODE" ]; then
    echo "Usage: $0 [default | log]"
    exit 1
fi

if [ -z "$FRAME_COUNT" ]; then
    FRAME_COUNT=1000
fi

if [ -z "$BATCH_SIZE" ]; then
    BATCH_SIZE=10
fi

echo "[RUN] run_multi_process1.sh"

./run_multi_process1.sh "$MODE" "$FRAME_COUNT" "$BATCH_SIZE" &

echo "[RUN] run_multi_process2.sh"
./run_multi_process2.sh "$MODE" "$FRAME_COUNT" "$BATCH_SIZE" &

echo "[RUN] run_multi_process3.sh"
./run_multi_process3.sh "$MODE" "$FRAME_COUNT" "$BATCH_SIZE" &

echo "[RUN] run_multi_process4.sh"
./run_multi_process4.sh "$MODE" "$FRAME_COUNT" "$BATCH_SIZE" &

echo "All multi-process scripts launched."
wait
