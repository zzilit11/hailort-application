#!/bin/bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly EXECUTABLE="${EXECUTABLE:-${SCRIPT_DIR}/build/multi_process}"
readonly MODEL="${MODEL:-/home/taespberry/WORKSPACE/official_models/resnet_v1_50.hef}"
readonly IMAGE="${IMAGE:-/home/taespberry/WORKSPACE/images/_images_1.png}"
readonly CLASS_LABELS="${CLASS_LABELS:-/home/taespberry/WORKSPACE/labels/imagenet_labels.json}"
readonly FRAME_COUNT="${FRAME_COUNT:-200}"
readonly BATCH_SIZE="${BATCH_SIZE:-10}"
readonly PRIORITY="${PRIORITY:-16}"
readonly SCHEDULER_TIMEOUT_MS="${SCHEDULER_TIMEOUT_MS:-200}"
readonly SCHEDULER_THRESHOLD="${SCHEDULER_THRESHOLD:-3}"
readonly RESULT_TOP_K="${RESULT_TOP_K:-3}"
readonly RESULT_LOG_EVERY="${RESULT_LOG_EVERY:-10}"
readonly RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-300}"
readonly ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE:-1}"
readonly VCTX_TRACE_PREAUTHORIZED="${VCTX_TRACE_PREAUTHORIZED:-0}"
readonly TRACE_HELPER="${TRACE_HELPER:-${SCRIPT_DIR}/../hailort-drivers/linux/pcie/tools/hailo_vctx_trace.sh}"
readonly RUN_ROOT="${RUN_ROOT:-${SCRIPT_DIR}/logs}"
readonly RUN_ID="$(date +'%Y%m%d-%H%M%S')-$$"
readonly RUN_DIR="${RUN_ROOT}/single-process-${RUN_ID}"
readonly WORKER_LOG="${RUN_DIR}/worker-single.log"
readonly TRACE_LOG="${RUN_DIR}/dmesg-vctx.log"
readonly RESULTS_LOG="${RUN_DIR}/inference-results.log"
readonly SUMMARY_LOG="${RUN_DIR}/summary.txt"

trace_pid=""

if (( EUID == 0 )); then
    echo "ERROR: do not run this inference script with sudo/root." >&2
    echo "Run it as the normal user; the VCTX trace helper elevates only sysfs/dmesg access." >&2
    exit 1
fi

stop_trace()
{
    if [[ -n "${trace_pid}" ]]; then
        if kill -0 "${trace_pid}" 2>/dev/null; then
            kill -INT -- "-${trace_pid}" 2>/dev/null || true
            for _ in {1..30}; do
                if ! kill -0 "${trace_pid}" 2>/dev/null; then
                    break
                fi
                sleep 0.1
            done
            if kill -0 "${trace_pid}" 2>/dev/null; then
                kill -TERM -- "-${trace_pid}" 2>/dev/null || true
            fi
        fi
        wait "${trace_pid}" 2>/dev/null || true
    fi
    trace_pid=""
}

cleanup()
{
    stop_trace
}

trap cleanup EXIT
trap 'exit 130' INT TERM

require_file()
{
    local description=$1
    local path=$2
    if [[ ! -f "${path}" ]]; then
        echo "ERROR: ${description} not found: ${path}" >&2
        exit 1
    fi
}

require_positive_integer()
{
    local name=$1
    local value=$2
    if [[ ! "${value}" =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: ${name} must be a positive integer: ${value}" >&2
        exit 1
    fi
}

require_nonnegative_integer()
{
    local name=$1
    local value=$2
    if [[ ! "${value}" =~ ^[0-9]+$ ]]; then
        echo "ERROR: ${name} must be a non-negative integer: ${value}" >&2
        exit 1
    fi
}

require_file "multi_process executable" "${EXECUTABLE}"
require_file "HEF" "${MODEL}"
require_file "image" "${IMAGE}"
require_file "labels" "${CLASS_LABELS}"
[[ -x "${EXECUTABLE}" ]] || { echo "ERROR: executable permission is missing: ${EXECUTABLE}" >&2; exit 1; }
require_positive_integer "FRAME_COUNT" "${FRAME_COUNT}"
require_positive_integer "BATCH_SIZE" "${BATCH_SIZE}"
require_nonnegative_integer "PRIORITY" "${PRIORITY}"
require_nonnegative_integer "SCHEDULER_TIMEOUT_MS" "${SCHEDULER_TIMEOUT_MS}"
require_nonnegative_integer "SCHEDULER_THRESHOLD" "${SCHEDULER_THRESHOLD}"
require_positive_integer "RESULT_TOP_K" "${RESULT_TOP_K}"
require_nonnegative_integer "RESULT_LOG_EVERY" "${RESULT_LOG_EVERY}"
require_positive_integer "RUN_TIMEOUT_SECONDS" "${RUN_TIMEOUT_SECONDS}"
if [[ "${VCTX_TRACE_PREAUTHORIZED}" != "0" && "${VCTX_TRACE_PREAUTHORIZED}" != "1" ]]; then
    echo "ERROR: VCTX_TRACE_PREAUTHORIZED must be 0 or 1." >&2
    exit 1
fi
command -v timeout >/dev/null 2>&1 || { echo "ERROR: GNU timeout is required." >&2; exit 1; }

mkdir -p "${RUN_DIR}"
{
    echo "run_id=${RUN_ID}"
    echo "mode=single-process-control"
    echo "executable=${EXECUTABLE}"
    echo "model=${MODEL}"
    echo "frames=${FRAME_COUNT}"
    echo "result_top_k=${RESULT_TOP_K}"
    echo "result_log_every=${RESULT_LOG_EVERY}"
    echo "multi_process_service=0"
    echo "vctx_trace=${ENABLE_VCTX_TRACE}"
    echo "vctx_trace_preauthorized=${VCTX_TRACE_PREAUTHORIZED}"
} | tee "${RUN_DIR}/configuration.txt"

if [[ "${ENABLE_VCTX_TRACE}" == "1" ]]; then
    require_file "vctx trace helper" "${TRACE_HELPER}"
    [[ -x "${TRACE_HELPER}" ]] || { echo "ERROR: trace helper is not executable: ${TRACE_HELPER}" >&2; exit 1; }
    command -v setsid >/dev/null 2>&1 || { echo "ERROR: setsid is required." >&2; exit 1; }
    if [[ "${VCTX_TRACE_PREAUTHORIZED}" != "1" ]]; then
        "${TRACE_HELPER}" --authorize
    fi
    setsid "${TRACE_HELPER}" --follow >"${TRACE_LOG}" 2>&1 &
    trace_pid=$!
    sleep 0.5
    if ! kill -0 "${trace_pid}" 2>/dev/null; then
        wait "${trace_pid}" || true
        echo "ERROR: vctx dmesg tracing failed to start. See ${TRACE_LOG}" >&2
        exit 1
    fi
elif [[ "${ENABLE_VCTX_TRACE}" != "0" ]]; then
    echo "ERROR: ENABLE_VCTX_TRACE must be 0 or 1." >&2
    exit 1
fi

echo "Launching one direct-mode control process..."
if timeout --signal=TERM --kill-after=5s "${RUN_TIMEOUT_SECONDS}s" \
    env HAILO_RESULT_TOP_K="${RESULT_TOP_K}" \
    HAILO_RESULT_LOG_EVERY="${RESULT_LOG_EVERY}" \
    "${EXECUTABLE}" "${MODEL}" "${IMAGE}" "${CLASS_LABELS}" \
    "${FRAME_COUNT}" "${BATCH_SIZE}" "${PRIORITY}" \
    "${SCHEDULER_TIMEOUT_MS}" "${SCHEDULER_THRESHOLD}" \
    >"${WORKER_LOG}" 2>&1; then
    worker_status=0
else
    worker_status=$?
fi

stop_trace

{
    echo "----- Single worker inference results -----"
    if ! grep -E 'inference-(result-(topk|summary)|score-validation)' "${WORKER_LOG}"; then
        echo "No decoded inference result was recorded."
    fi
} | tee "${RESULTS_LOG}"

transport_result="PASS"
classification_result="PASS"
if ! grep -q 'inference-transport-complete status=0' "${WORKER_LOG}"; then
    transport_result="FAIL"
fi
if ! grep -q 'inference-result-summary.*classification_result=PASS' "${WORKER_LOG}" ||
   grep -q 'inference-result-summary.*classification_result=FAIL' "${WORKER_LOG}"; then
    classification_result="FAIL"
fi

stall_warning_count=0
ring_wrap_count=0
cursor_rebase_failure_count=0
score_validation_failure_count="$(grep -c 'inference-result-summary.*score_validation=FAIL' "${WORKER_LOG}" || true)"
if [[ "${ENABLE_VCTX_TRACE}" == "1" && -f "${TRACE_LOG}" ]]; then
    stall_warning_count="$(grep -c 'TRANSFER_STALL_WARN' "${TRACE_LOG}" || true)"
    ring_wrap_count="$(grep -c 'TRANSFER_COMMIT.*logical_ring_wrap=1' "${TRACE_LOG}" || true)"
    cursor_rebase_failure_count="$(grep -c 'CHANNEL_CURSOR_REBASE.*physical_idle_failed=1' "${TRACE_LOG}" || true)"
fi
if (( cursor_rebase_failure_count != 0 || stall_warning_count != 0 )); then
    transport_result="FAIL"
fi
result="PASS"
if [[ "${transport_result}" != "PASS" || "${classification_result}" != "PASS" ]]; then
    result="FAIL"
fi

{
    echo "result=${result}"
    echo "transport_result=${transport_result}"
    echo "classification_result=${classification_result}"
    # Compatibility alias for existing log consumers.
    echo "score_result=${classification_result}"
    echo "worker_exit=${worker_status}"
    echo "frames=${FRAME_COUNT}"
    echo "ring_wrap_commits=${ring_wrap_count}"
    echo "cursor_rebase_failures=${cursor_rebase_failure_count}"
    echo "stall_warnings=${stall_warning_count}"
    echo "score_validation_failures=${score_validation_failure_count}"
    echo "worker_log=${WORKER_LOG}"
    echo "inference_results_log=${RESULTS_LOG}"
    if [[ "${ENABLE_VCTX_TRACE}" == "1" ]]; then
        echo "dmesg_log=${TRACE_LOG}"
    fi
} | tee "${SUMMARY_LOG}"

if [[ "${result}" != "PASS" ]]; then
    echo "Single-process control failed; inspect ${RUN_DIR}." >&2
    tail -n 30 "${WORKER_LOG}" >&2 || true
    exit 1
fi

echo "Single-process control passed. Logs: ${RUN_DIR}"
