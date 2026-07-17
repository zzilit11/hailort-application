#!/bin/bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
source "${APP_DIR}/scripts/lib/vctx_common.sh"

# Paths may be overridden without editing this script, for example:
# MODEL_B=/path/to/another.hef FRAME_COUNT=500 ./scripts/run/run_inference_multi.sh
readonly EXECUTABLE="${EXECUTABLE:-${APP_DIR}/build/multi_process}"
readonly MODEL_A="${MODEL_A:-/home/taespberry/WORKSPACE/official_models/resnet_v1_50.hef}"
readonly MODEL_B="${MODEL_B:-${MODEL_A}}"
readonly IMAGE_A="${IMAGE_A:-/home/taespberry/WORKSPACE/images/_images_1.png}"
readonly IMAGE_B="${IMAGE_B:-${IMAGE_A}}"
readonly CLASS_LABELS_A="${CLASS_LABELS_A:-/home/taespberry/WORKSPACE/labels/imagenet_labels.json}"
readonly CLASS_LABELS_B="${CLASS_LABELS_B:-${CLASS_LABELS_A}}"

readonly FRAME_COUNT_A="${FRAME_COUNT_A:-${FRAME_COUNT:-200}}"
readonly FRAME_COUNT_B="${FRAME_COUNT_B:-${FRAME_COUNT:-200}}"
readonly BATCH_SIZE_A="${BATCH_SIZE_A:-${BATCH_SIZE:-10}}"
readonly BATCH_SIZE_B="${BATCH_SIZE_B:-${BATCH_SIZE:-10}}"
readonly PRIORITY_A="${PRIORITY_A:-${PRIORITY:-16}}"
readonly PRIORITY_B="${PRIORITY_B:-${PRIORITY:-16}}"
readonly SCHEDULER_TIMEOUT_MS_A="${SCHEDULER_TIMEOUT_MS_A:-${SCHEDULER_TIMEOUT_MS:-200}}"
readonly SCHEDULER_TIMEOUT_MS_B="${SCHEDULER_TIMEOUT_MS_B:-${SCHEDULER_TIMEOUT_MS:-200}}"
readonly SCHEDULER_THRESHOLD_A="${SCHEDULER_THRESHOLD_A:-${SCHEDULER_THRESHOLD:-3}}"
readonly SCHEDULER_THRESHOLD_B="${SCHEDULER_THRESHOLD_B:-${SCHEDULER_THRESHOLD:-3}}"
readonly RESULT_TOP_K="${RESULT_TOP_K:-3}"
readonly RESULT_LOG_EVERY="${RESULT_LOG_EVERY:-10}"

readonly READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-120}"
readonly RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-300}"
readonly ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE:-1}"
readonly VCTX_TRACE_SESSION_UID="$(id -u)"
readonly EXTERNAL_TRACE_STATE_FILE="${HAILO_VCTX_TRACE_STATE_FILE:-/tmp/hailo-vctx-trace-${VCTX_TRACE_SESSION_UID}.state}"
readonly RUN_ROOT="${RUN_ROOT:-${APP_DIR}/logs}"
readonly RUN_ID="$(date +'%Y%m%d-%H%M%S')-$$"
readonly RUN_DIR="${RUN_ROOT}/multi-process-${RUN_ID}"
readonly BARRIER_DIR="${RUN_DIR}/barrier"
readonly WORKER_A_LOG="${RUN_DIR}/worker-A.log"
readonly WORKER_B_LOG="${RUN_DIR}/worker-B.log"
readonly TRACE_LOG="${RUN_DIR}/dmesg-vctx.log"
readonly TRACE_READER_LOG="${RUN_DIR}/dmesg-reader.log"
readonly RESULTS_LOG="${RUN_DIR}/inference-results.log"
readonly SUMMARY_LOG="${RUN_DIR}/summary.txt"
readonly VCTX_QUANTUM_MS_PARAMETER="/sys/module/hailo_pci/parameters/vctx_dispatch_quantum_ms"
readonly VCTX_QUANTUM_TRANSFERS_PARAMETER="/sys/module/hailo_pci/parameters/vctx_dispatch_quantum_transfers"

worker_a_pid=""
worker_b_pid=""
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
    local exit_code=$?
    trap - EXIT INT TERM

    for pid in "${worker_a_pid}" "${worker_b_pid}"; do
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done
    stop_trace || true

    if (( 0 != exit_code )); then
        echo "Experiment failed. Logs: ${RUN_DIR}" >&2
        [[ -f "${WORKER_A_LOG}" ]] && tail -n 20 "${WORKER_A_LOG}" >&2 || true
        [[ -f "${WORKER_B_LOG}" ]] && tail -n 20 "${WORKER_B_LOG}" >&2 || true
    fi
    exit "${exit_code}"
}

trap cleanup EXIT INT TERM

require_file "multi_process executable" "${EXECUTABLE}"
if [[ ! -x "${EXECUTABLE}" ]]; then
    echo "ERROR: executable permission is missing: ${EXECUTABLE}" >&2
    exit 1
fi
require_file "worker A HEF" "${MODEL_A}"
require_file "worker B HEF" "${MODEL_B}"
require_file "worker A image" "${IMAGE_A}"
require_file "worker B image" "${IMAGE_B}"
require_file "worker A labels" "${CLASS_LABELS_A}"
require_file "worker B labels" "${CLASS_LABELS_B}"

require_positive_integer "FRAME_COUNT_A" "${FRAME_COUNT_A}"
require_positive_integer "FRAME_COUNT_B" "${FRAME_COUNT_B}"
require_positive_integer "BATCH_SIZE_A" "${BATCH_SIZE_A}"
require_positive_integer "BATCH_SIZE_B" "${BATCH_SIZE_B}"
require_nonnegative_integer "PRIORITY_A" "${PRIORITY_A}"
require_nonnegative_integer "PRIORITY_B" "${PRIORITY_B}"
require_nonnegative_integer "SCHEDULER_TIMEOUT_MS_A" "${SCHEDULER_TIMEOUT_MS_A}"
require_nonnegative_integer "SCHEDULER_TIMEOUT_MS_B" "${SCHEDULER_TIMEOUT_MS_B}"
require_nonnegative_integer "SCHEDULER_THRESHOLD_A" "${SCHEDULER_THRESHOLD_A}"
require_nonnegative_integer "SCHEDULER_THRESHOLD_B" "${SCHEDULER_THRESHOLD_B}"
require_positive_integer "RESULT_TOP_K" "${RESULT_TOP_K}"
require_nonnegative_integer "RESULT_LOG_EVERY" "${RESULT_LOG_EVERY}"
require_positive_integer "READY_TIMEOUT_SECONDS" "${READY_TIMEOUT_SECONDS}"
require_positive_integer "RUN_TIMEOUT_SECONDS" "${RUN_TIMEOUT_SECONDS}"
if ! command -v timeout >/dev/null 2>&1; then
    echo "ERROR: GNU timeout is required to bound worker execution time." >&2
    exit 1
fi

mkdir -p "${BARRIER_DIR}"

vctx_quantum_ms="$(read_module_parameter "${VCTX_QUANTUM_MS_PARAMETER}")"
vctx_quantum_transfers="$(read_module_parameter "${VCTX_QUANTUM_TRANSFERS_PARAMETER}")"

{
    echo "run_id=${RUN_ID}"
    echo "executable=${EXECUTABLE}"
    echo "worker_A_model=${MODEL_A}"
    echo "worker_B_model=${MODEL_B}"
    echo "worker_A_frames=${FRAME_COUNT_A}"
    echo "worker_B_frames=${FRAME_COUNT_B}"
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

echo "Launching two independent direct-mode processes..."

timeout --signal=TERM --kill-after=5s "${RUN_TIMEOUT_SECONDS}s" \
    env HAILO_RESULT_TOP_K="${RESULT_TOP_K}" \
    HAILO_RESULT_LOG_EVERY="${RESULT_LOG_EVERY}" \
    "${EXECUTABLE}" "${MODEL_A}" "${IMAGE_A}" "${CLASS_LABELS_A}" \
    "${FRAME_COUNT_A}" "${BATCH_SIZE_A}" "${PRIORITY_A}" \
    "${SCHEDULER_TIMEOUT_MS_A}" "${SCHEDULER_THRESHOLD_A}" \
    A "${BARRIER_DIR}" >"${WORKER_A_LOG}" 2>&1 &
worker_a_pid=$!

timeout --signal=TERM --kill-after=5s "${RUN_TIMEOUT_SECONDS}s" \
    env HAILO_RESULT_TOP_K="${RESULT_TOP_K}" \
    HAILO_RESULT_LOG_EVERY="${RESULT_LOG_EVERY}" \
    "${EXECUTABLE}" "${MODEL_B}" "${IMAGE_B}" "${CLASS_LABELS_B}" \
    "${FRAME_COUNT_B}" "${BATCH_SIZE_B}" "${PRIORITY_B}" \
    "${SCHEDULER_TIMEOUT_MS_B}" "${SCHEDULER_THRESHOLD_B}" \
    B "${BARRIER_DIR}" >"${WORKER_B_LOG}" 2>&1 &
worker_b_pid=$!

readonly ready_deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
while [[ ! -f "${BARRIER_DIR}/ready.A" || ! -f "${BARRIER_DIR}/ready.B" ]]; do
    if ! kill -0 "${worker_a_pid}" 2>/dev/null; then
        echo "ERROR: worker A exited before reaching the start barrier." >&2
        exit 1
    fi
    if ! kill -0 "${worker_b_pid}" 2>/dev/null; then
        echo "ERROR: worker B exited before reaching the start barrier." >&2
        exit 1
    fi
    if (( SECONDS >= ready_deadline )); then
        echo "ERROR: workers did not both become ready within ${READY_TIMEOUT_SECONDS}s." >&2
        exit 1
    fi
    sleep 0.05
done

# Atomic publication prevents either worker from observing a partially written
# marker. Both workers have completed device/model/VStream initialization here.
printf 'release_unix_ms=%s\n' "$(date +%s%3N)" >"${BARRIER_DIR}/start.tmp"
mv "${BARRIER_DIR}/start.tmp" "${BARRIER_DIR}/start"
echo "Both workers ready; inference barrier released."

if wait "${worker_a_pid}"; then
    status_a=0
else
    status_a=$?
fi
if wait "${worker_b_pid}"; then
    status_b=0
else
    status_b=$?
fi
worker_a_pid=""
worker_b_pid=""

stop_trace

print_worker_results()
{
    local worker_name=$1
    local worker_log=$2

    echo "----- Worker ${worker_name} inference results -----"
    if ! grep -E 'inference-(result-(topk|summary)|score-validation)' "${worker_log}"; then
        echo "No decoded inference result was recorded for worker ${worker_name}."
    fi
}

{
    print_worker_results "A" "${WORKER_A_LOG}"
    print_worker_results "B" "${WORKER_B_LOG}"
} | tee "${RESULTS_LOG}"

extract_last_value()
{
    local key=$1
    local log_path=$2
    grep -o "${key}=[0-9]*" "${log_path}" | tail -n 1 | cut -d= -f2
}

extract_configuration_value()
{
    local key=$1
    local log_path=$2

    grep 'configuration-complete' "${log_path}" |
        grep -o "${key}=[0-9]*" | tail -n 1 | cut -d= -f2
}

start_a="$(extract_last_value start_unix_ms "${WORKER_A_LOG}" || true)"
start_b="$(extract_last_value start_unix_ms "${WORKER_B_LOG}" || true)"
end_a="$(extract_last_value end_unix_ms "${WORKER_A_LOG}" || true)"
end_b="$(extract_last_value end_unix_ms "${WORKER_B_LOG}" || true)"
input_streams_a="$(extract_configuration_value inputs "${WORKER_A_LOG}" || true)"
output_streams_a="$(extract_configuration_value outputs "${WORKER_A_LOG}" || true)"
input_streams_b="$(extract_configuration_value inputs "${WORKER_B_LOG}" || true)"
output_streams_b="$(extract_configuration_value outputs "${WORKER_B_LOG}" || true)"

overlap_ms=0
if [[ "${start_a}" =~ ^[0-9]+$ && "${start_b}" =~ ^[0-9]+$ && \
      "${end_a}" =~ ^[0-9]+$ && "${end_b}" =~ ^[0-9]+$ ]]; then
    (( start_a > start_b )) && overlap_start=${start_a} || overlap_start=${start_b}
    (( end_a < end_b )) && overlap_end=${end_a} || overlap_end=${end_b}
    if (( overlap_end > overlap_start )); then
        overlap_ms=$((overlap_end - overlap_start))
    fi
fi

vctx_count=0
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
if [[ "${ENABLE_VCTX_TRACE}" == "1" && -f "${TRACE_LOG}" ]]; then
    if [[ "${input_streams_a}" =~ ^[1-9][0-9]*$ &&
          "${output_streams_a}" =~ ^[1-9][0-9]*$ &&
          "${input_streams_b}" =~ ^[1-9][0-9]*$ &&
          "${output_streams_b}" =~ ^[1-9][0-9]*$ ]]; then
        trace_expected_transfer_count=$((
            FRAME_COUNT_A * (input_streams_a + output_streams_a) +
            FRAME_COUNT_B * (input_streams_b + output_streams_b)
        ))
    fi
    vctx_count="$(grep -Eo 'vctx=[0-9]+' "${TRACE_LOG}" | sort -u | wc -l || true)"
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
score_validation_failure_count_a="$(grep -c 'inference-result-summary.*score_validation=FAIL' "${WORKER_A_LOG}" || true)"
score_validation_failure_count_b="$(grep -c 'inference-result-summary.*score_validation=FAIL' "${WORKER_B_LOG}" || true)"
classification_pass_count_a="$(grep -c 'inference-result-summary.*classification_result=PASS' "${WORKER_A_LOG}" || true)"
classification_pass_count_b="$(grep -c 'inference-result-summary.*classification_result=PASS' "${WORKER_B_LOG}" || true)"
classification_failure_count_a="$(grep -c 'inference-result-summary.*classification_result=FAIL' "${WORKER_A_LOG}" || true)"
classification_failure_count_b="$(grep -c 'inference-result-summary.*classification_result=FAIL' "${WORKER_B_LOG}" || true)"

transport_result="PASS"
classification_result="PASS"
if ! grep -q 'inference-transport-complete status=0' "${WORKER_A_LOG}" || \
   ! grep -q 'inference-transport-complete status=0' "${WORKER_B_LOG}"; then
    transport_result="FAIL"
fi
if (( classification_pass_count_a == 0 || classification_pass_count_b == 0 ||
      classification_failure_count_a != 0 || classification_failure_count_b != 0 )); then
    classification_result="FAIL"
fi
if (( cursor_rebase_failure_count != 0 || stall_warning_count != 0 )); then
    transport_result="FAIL"
fi
if (( overlap_ms <= 0 )); then
    transport_result="FAIL"
fi
if [[ "${ENABLE_VCTX_TRACE}" == "1" ]] && (( vctx_count < 2 )); then
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
    echo "worker_A_exit=${status_a}"
    echo "worker_B_exit=${status_b}"
    echo "worker_A_interval_ms=${start_a:-unknown}..${end_a:-unknown}"
    echo "worker_B_interval_ms=${start_b:-unknown}..${end_b:-unknown}"
    echo "inference_overlap_ms=${overlap_ms}"
    echo "unique_vctx_count=${vctx_count}"
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
    echo "worker_A_score_validation_failures=${score_validation_failure_count_a}"
    echo "worker_B_score_validation_failures=${score_validation_failure_count_b}"
    echo "worker_A_classification_failures=${classification_failure_count_a}"
    echo "worker_B_classification_failures=${classification_failure_count_b}"
    echo "worker_A_log=${WORKER_A_LOG}"
    echo "worker_B_log=${WORKER_B_LOG}"
    echo "inference_results_log=${RESULTS_LOG}"
    if [[ "${ENABLE_VCTX_TRACE}" == "1" ]]; then
        echo "dmesg_log=${TRACE_LOG}"
        echo "dmesg_reader_log=${TRACE_READER_LOG}"
    fi
} | tee "${SUMMARY_LOG}"

if [[ "${result}" != "PASS" ]]; then
    echo "Two-process verification failed; inspect ${RUN_DIR}." >&2
    exit 1
fi

echo "Two-process direct-mode verification passed. Logs: ${RUN_DIR}"
