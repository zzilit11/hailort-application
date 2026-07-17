#!/bin/bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
source "${APP_DIR}/scripts/lib/vctx_common.sh"
readonly EXECUTABLE="${EXECUTABLE:-${APP_DIR}/build/multi_process}"
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
readonly VCTX_TRACE_SESSION_UID="$(id -u)"
readonly EXTERNAL_TRACE_STATE_FILE="${HAILO_VCTX_TRACE_STATE_FILE:-/tmp/hailo-vctx-trace-${VCTX_TRACE_SESSION_UID}.state}"
readonly RUN_ROOT="${RUN_ROOT:-${APP_DIR}/logs}"
readonly RUN_ID="$(date +'%Y%m%d-%H%M%S')-$$"
readonly RUN_DIR="${RUN_ROOT}/single-process-${RUN_ID}"
readonly WORKER_LOG="${RUN_DIR}/worker-single.log"
readonly TRACE_LOG="${RUN_DIR}/dmesg-vctx.log"
readonly TRACE_READER_LOG="${RUN_DIR}/dmesg-reader.log"
readonly RESULTS_LOG="${RUN_DIR}/inference-results.log"
readonly SUMMARY_LOG="${RUN_DIR}/summary.txt"
readonly VCTX_QUANTUM_MS_PARAMETER="/sys/module/hailo_pci/parameters/vctx_dispatch_quantum_ms"
readonly VCTX_QUANTUM_TRANSFERS_PARAMETER="/sys/module/hailo_pci/parameters/vctx_dispatch_quantum_transfers"

external_trace_pid=""
external_trace_producer_pid=""
external_trace_log=""
external_trace_error_log=""
external_trace_start_line=0
external_trace_error_start_line=0
external_trace_active=0
external_trace_captured=0
external_trace_capture_status=0

if (( EUID == 0 )); then
    echo "ERROR: do not run this inference script with sudo/root." >&2
    echo "Run it as the normal user after starting hailo_vctx_trace.sh separately." >&2
    exit 1
fi

cleanup()
{
    stop_trace || true
}

trap cleanup EXIT
trap 'exit 130' INT TERM

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
command -v timeout >/dev/null 2>&1 || { echo "ERROR: GNU timeout is required." >&2; exit 1; }

mkdir -p "${RUN_DIR}"
vctx_quantum_ms="$(read_module_parameter "${VCTX_QUANTUM_MS_PARAMETER}")"
vctx_quantum_transfers="$(read_module_parameter "${VCTX_QUANTUM_TRANSFERS_PARAMETER}")"
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
    echo "vctx_trace_mode=external"
    echo "external_trace_state_file=${EXTERNAL_TRACE_STATE_FILE}"
    echo "vctx_dispatch_quantum_ms=${vctx_quantum_ms}"
    echo "vctx_dispatch_quantum_transfers=${vctx_quantum_transfers}"
} | tee "${RUN_DIR}/configuration.txt"

if [[ "${ENABLE_VCTX_TRACE}" == "1" ]]; then
    prepare_external_trace
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

extract_configuration_value()
{
    local key=$1
    local log_path=$2

    grep 'configuration-complete' "${log_path}" |
        grep -o "${key}=[0-9]*" | tail -n 1 | cut -d= -f2
}

input_streams="$(extract_configuration_value inputs "${WORKER_LOG}" || true)"
output_streams="$(extract_configuration_value outputs "${WORKER_LOG}" || true)"

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
device_switch_count=0
quantum_begin_count=0
quantum_request_count=0
trace_expected_transfer_count=0
trace_queue_count=0
trace_commit_count=0
trace_complete_count=0
trace_reader_error_count=0
trace_result="DISABLED"
score_validation_failure_count="$(grep -c 'inference-result-summary.*score_validation=FAIL' "${WORKER_LOG}" || true)"
if [[ "${ENABLE_VCTX_TRACE}" == "1" && -f "${TRACE_LOG}" ]]; then
    if [[ "${input_streams}" =~ ^[1-9][0-9]*$ &&
          "${output_streams}" =~ ^[1-9][0-9]*$ ]]; then
        trace_expected_transfer_count=$((FRAME_COUNT * (input_streams + output_streams)))
    fi
    stall_warning_count="$(grep -c 'TRANSFER_STALL_WARN' "${TRACE_LOG}" || true)"
    ring_wrap_count="$(grep -c 'TRANSFER_COMMIT.*logical_ring_wrap=1' "${TRACE_LOG}" || true)"
    cursor_rebase_failure_count="$(grep -c 'CHANNEL_CURSOR_REBASE.*physical_idle_failed=1' "${TRACE_LOG}" || true)"
    device_switch_count="$(grep -c 'DEVICE_SWITCH' "${TRACE_LOG}" || true)"
    quantum_begin_count="$(grep -c 'VCTX_QUANTUM_BEGIN' "${TRACE_LOG}" || true)"
    quantum_request_count="$(grep -c 'VCTX_QUANTUM_REQUEST' "${TRACE_LOG}" || true)"
    trace_queue_count="$(grep -c 'TRANSFER_QUEUE' "${TRACE_LOG}" || true)"
    trace_commit_count="$(grep -c 'TRANSFER_COMMIT' "${TRACE_LOG}" || true)"
    trace_complete_count="$(grep -c 'TRANSFER_COMPLETE' "${TRACE_LOG}" || true)"
    if [[ -f "${TRACE_READER_LOG}" ]]; then
        trace_reader_error_count="$(wc -l <"${TRACE_READER_LOG}")"
    fi
    trace_result="PASS"
    if (( external_trace_capture_status != 0 || trace_reader_error_count != 0 ||
          trace_expected_transfer_count == 0 ||
          trace_queue_count != trace_expected_transfer_count ||
          trace_commit_count != trace_expected_transfer_count ||
          trace_complete_count != trace_expected_transfer_count )); then
        trace_result="FAIL"
    fi
fi
if [[ "${trace_result}" == "FAIL" ]]; then
    echo "ERROR: incomplete VCTX trace: expected=${trace_expected_transfer_count} queue=${trace_queue_count} commit=${trace_commit_count} complete=${trace_complete_count} reader_errors=${trace_reader_error_count} capture_status=${external_trace_capture_status}" >&2
fi
if (( cursor_rebase_failure_count != 0 || stall_warning_count != 0 )); then
    transport_result="FAIL"
fi
result="PASS"
if [[ "${transport_result}" != "PASS" || "${classification_result}" != "PASS" ||
      "${trace_result}" == "FAIL" ]]; then
    result="FAIL"
fi

{
    echo "result=${result}"
    echo "transport_result=${transport_result}"
    echo "classification_result=${classification_result}"
    echo "trace_result=${trace_result}"
    # Compatibility alias for existing log consumers.
    echo "score_result=${classification_result}"
    echo "worker_exit=${worker_status}"
    echo "frames=${FRAME_COUNT}"
    echo "ring_wrap_commits=${ring_wrap_count}"
    echo "cursor_rebase_failures=${cursor_rebase_failure_count}"
    echo "stall_warnings=${stall_warning_count}"
    echo "device_switches=${device_switch_count}"
    echo "quantum_begins=${quantum_begin_count}"
    echo "quantum_requests=${quantum_request_count}"
    echo "trace_expected_transfers=${trace_expected_transfer_count}"
    echo "trace_queue_events=${trace_queue_count}"
    echo "trace_commit_events=${trace_commit_count}"
    echo "trace_complete_events=${trace_complete_count}"
    echo "trace_reader_errors=${trace_reader_error_count}"
    echo "trace_capture_status=${external_trace_capture_status}"
    echo "score_validation_failures=${score_validation_failure_count}"
    echo "worker_log=${WORKER_LOG}"
    echo "inference_results_log=${RESULTS_LOG}"
    if [[ "${ENABLE_VCTX_TRACE}" == "1" ]]; then
        echo "dmesg_log=${TRACE_LOG}"
        echo "dmesg_reader_log=${TRACE_READER_LOG}"
    fi
} | tee "${SUMMARY_LOG}"

if [[ "${result}" != "PASS" ]]; then
    echo "Single-process control failed; inspect ${RUN_DIR}." >&2
    tail -n 30 "${WORKER_LOG}" >&2 || true
    exit 1
fi

echo "Single-process control passed. Logs: ${RUN_DIR}"
