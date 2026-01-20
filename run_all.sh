#!/bin/bash
set -e

sudo systemctl restart hailort.service

CONFIG_FILE="configuration.json"
WORKER_SCRIPT="./run_worker.sh"

# jq 설치 확인
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed. Install it using 'sudo apt install jq'"
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Configuration file $CONFIG_FILE not found."
    exit 1
fi

# Global Settings 파싱
MODE=$(jq -r '.global_settings.mode' "$CONFIG_FILE")
LOG_DIR=$(jq -r '.global_settings.log_dir' "$CONFIG_FILE")

# 로그 디렉토리 초기화
rm -rf "$LOG_DIR"
mkdir -p "$LOG_DIR"

echo "============================================"
echo " Starting Multi-Process Manager (JSON Config)"
echo " Mode: $MODE"
echo "============================================"

# Jobs 배열 순회
# jq -c를 사용하여 각 객체를 한 줄의 문자열로 추출
jq -c '.jobs[]' "$CONFIG_FILE" | while read -r job; do
    
    # 각 필드 추출
    ID=$(echo "$job" | jq -r '.id')
    HEF=$(echo "$job" | jq -r '.hef_path')
    IMAGE=$(echo "$job" | jq -r '.image_path')
    LABEL=$(echo "$job" | jq -r '.labels_path')
    FRAMES=$(echo "$job" | jq -r '.frame_count')
    BATCH=$(echo "$job" | jq -r '.batch_size')
    PRIORITY=$(echo "$job" | jq -r '.priority')
    TIMEOUT=$(echo "$job" | jq -r '.timeout_ms')
    THRESHOLD=$(echo "$job" | jq -r '.threshold')
    INSTANCES=$(echo "$job" | jq -r '.instances')

    echo ">> Launching Job Set #$ID"
    echo "   - Model: $(basename "$HEF")"
    
    # Instance 수만큼 반복 실행
    for (( i=1; i<=INSTANCES; i++ )); do
        LOG_FILE="$LOG_DIR/job_${ID}_${i}.log"
        
        # 워커 스크립트 실행
        "$WORKER_SCRIPT" \
            "$MODE" "$HEF" "$IMAGE" "$LABEL" \
            "$FRAMES" "$BATCH" "$PRIORITY" "$TIMEOUT" "$THRESHOLD" \
            "$LOG_FILE"
    done
done

echo "All jobs launched."
wait