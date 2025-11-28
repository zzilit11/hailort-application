#!/bin/bash
set -e

MODE="$1"

echo "[RUN] run_multi_process1.sh"

./run_multi_process1.sh "$MODE" &

echo "[RUN] run_multi_process2.sh"
./run_multi_process2.sh "$MODE" &

echo "[RUN] run_multi_process3.sh"
./run_multi_process3.sh "$MODE" &

echo "[RUN] run_multi_process4.sh"
./run_multi_process4.sh "$MODE" &

echo "All multi-process scripts launched."
wait
