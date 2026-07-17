#!/usr/bin/env bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
source "${APP_DIR}/scripts/lib/vctx_common.sh"

readonly EXECUTABLE="${EXECUTABLE:-${APP_DIR}/build/multi_process}"
readonly DEFAULT_MODEL="/home/taespberry/WORKSPACE/official_models/resnet_v1_50.hef"
readonly DEFAULT_IMAGE="/home/taespberry/WORKSPACE/images/_images_1.png"
readonly DEFAULT_CLASS_LABELS="/home/taespberry/WORKSPACE/labels/imagenet_labels.json"

readonly MODEL_A="${MODEL_A:-${DEFAULT_MODEL}}"
readonly MODEL_B="${MODEL_B:-${MODEL_A}}"
readonly MODEL_C="${MODEL_C:-${MODEL_A}}"
readonly MODEL_D="${MODEL_D:-${MODEL_A}}"
readonly IMAGE_A="${IMAGE_A:-${DEFAULT_IMAGE}}"
readonly IMAGE_B="${IMAGE_B:-${IMAGE_A}}"
readonly IMAGE_C="${IMAGE_C:-${IMAGE_A}}"
readonly IMAGE_D="${IMAGE_D:-${IMAGE_A}}"
readonly CLASS_LABELS_A="${CLASS_LABELS_A:-${DEFAULT_CLASS_LABELS}}"
readonly CLASS_LABELS_B="${CLASS_LABELS_B:-${CLASS_LABELS_A}}"
readonly CLASS_LABELS_C="${CLASS_LABELS_C:-${CLASS_LABELS_A}}"
readonly CLASS_LABELS_D="${CLASS_LABELS_D:-${CLASS_LABELS_A}}"

readonly FRAME_COUNT_A="${FRAME_COUNT_A:-${FRAME_COUNT:-200}}"
readonly FRAME_COUNT_B="${FRAME_COUNT_B:-${FRAME_COUNT:-200}}"
readonly FRAME_COUNT_C="${FRAME_COUNT_C:-${FRAME_COUNT:-200}}"
readonly FRAME_COUNT_D="${FRAME_COUNT_D:-${FRAME_COUNT:-200}}"
readonly BATCH_SIZE_A="${BATCH_SIZE_A:-${BATCH_SIZE:-10}}"
readonly BATCH_SIZE_B="${BATCH_SIZE_B:-${BATCH_SIZE:-10}}"
readonly BATCH_SIZE_C="${BATCH_SIZE_C:-${BATCH_SIZE:-10}}"
readonly BATCH_SIZE_D="${BATCH_SIZE_D:-${BATCH_SIZE:-10}}"
readonly PRIORITY_A="${PRIORITY_A:-${PRIORITY:-16}}"
readonly PRIORITY_B="${PRIORITY_B:-${PRIORITY:-16}}"
readonly PRIORITY_C="${PRIORITY_C:-${PRIORITY:-16}}"
readonly PRIORITY_D="${PRIORITY_D:-${PRIORITY:-16}}"
readonly SCHEDULER_TIMEOUT_MS_A="${SCHEDULER_TIMEOUT_MS_A:-${SCHEDULER_TIMEOUT_MS:-200}}"
readonly SCHEDULER_TIMEOUT_MS_B="${SCHEDULER_TIMEOUT_MS_B:-${SCHEDULER_TIMEOUT_MS:-200}}"
readonly SCHEDULER_TIMEOUT_MS_C="${SCHEDULER_TIMEOUT_MS_C:-${SCHEDULER_TIMEOUT_MS:-200}}"
readonly SCHEDULER_TIMEOUT_MS_D="${SCHEDULER_TIMEOUT_MS_D:-${SCHEDULER_TIMEOUT_MS:-200}}"
readonly SCHEDULER_THRESHOLD_A="${SCHEDULER_THRESHOLD_A:-${SCHEDULER_THRESHOLD:-3}}"
readonly SCHEDULER_THRESHOLD_B="${SCHEDULER_THRESHOLD_B:-${SCHEDULER_THRESHOLD:-3}}"
readonly SCHEDULER_THRESHOLD_C="${SCHEDULER_THRESHOLD_C:-${SCHEDULER_THRESHOLD:-3}}"
readonly SCHEDULER_THRESHOLD_D="${SCHEDULER_THRESHOLD_D:-${SCHEDULER_THRESHOLD:-3}}"

# Override these when the target exposes a different CPU numbering scheme.
readonly CPU_CORE_A="${CPU_CORE_A:-0}"
readonly CPU_CORE_B="${CPU_CORE_B:-1}"
readonly CPU_CORE_C="${CPU_CORE_C:-2}"
readonly CPU_CORE_D="${CPU_CORE_D:-3}"

readonly RESULT_TOP_K="${RESULT_TOP_K:-3}"
readonly RESULT_LOG_EVERY="${RESULT_LOG_EVERY:-10}"
readonly READY_TIMEOUT_SECONDS="${READY_TIMEOUT_SECONDS:-120}"
readonly RUN_TIMEOUT_SECONDS="${RUN_TIMEOUT_SECONDS:-300}"
readonly ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE:-1}"
readonly VCTX_TRACE_SESSION_UID="$(id -u)"
readonly EXTERNAL_TRACE_STATE_FILE="${HAILO_VCTX_TRACE_STATE_FILE:-/tmp/hailo-vctx-trace-${VCTX_TRACE_SESSION_UID}.state}"
readonly RUN_ROOT="${RUN_ROOT:-${APP_DIR}/logs}"
readonly RUN_ID="$(date +'%Y%m%d-%H%M%S')-$$"
readonly RUN_DIR="${RUN_ROOT}/vctx-four-${RUN_ID}"
readonly BARRIER_DIR="${RUN_DIR}/barrier"
readonly TRACE_LOG="${RUN_DIR}/dmesg-vctx.log"
readonly TRACE_READER_LOG="${RUN_DIR}/dmesg-reader.log"
readonly RESULTS_LOG="${RUN_DIR}/inference-results.log"
readonly SUMMARY_LOG="${RUN_DIR}/summary.txt"
readonly VCTX_QUANTUM_MS_PARAMETER="/sys/module/hailo_pci/parameters/vctx_dispatch_quantum_ms"
readonly VCTX_QUANTUM_TRANSFERS_PARAMETER="/sys/module/hailo_pci/parameters/vctx_dispatch_quantum_transfers"

declare -ar WORKER_IDS=(A B C D)
declare -ar MODELS=("${MODEL_A}" "${MODEL_B}" "${MODEL_C}" "${MODEL_D}")
declare -ar IMAGES=("${IMAGE_A}" "${IMAGE_B}" "${IMAGE_C}" "${IMAGE_D}")
declare -ar CLASS_LABELS=("${CLASS_LABELS_A}" "${CLASS_LABELS_B}" "${CLASS_LABELS_C}" "${CLASS_LABELS_D}")
declare -ar FRAME_COUNTS=("${FRAME_COUNT_A}" "${FRAME_COUNT_B}" "${FRAME_COUNT_C}" "${FRAME_COUNT_D}")
declare -ar BATCH_SIZES=("${BATCH_SIZE_A}" "${BATCH_SIZE_B}" "${BATCH_SIZE_C}" "${BATCH_SIZE_D}")
declare -ar PRIORITIES=("${PRIORITY_A}" "${PRIORITY_B}" "${PRIORITY_C}" "${PRIORITY_D}")
declare -ar SCHEDULER_TIMEOUTS_MS=("${SCHEDULER_TIMEOUT_MS_A}" "${SCHEDULER_TIMEOUT_MS_B}" "${SCHEDULER_TIMEOUT_MS_C}" "${SCHEDULER_TIMEOUT_MS_D}")
declare -ar SCHEDULER_THRESHOLDS=("${SCHEDULER_THRESHOLD_A}" "${SCHEDULER_THRESHOLD_B}" "${SCHEDULER_THRESHOLD_C}" "${SCHEDULER_THRESHOLD_D}")
declare -ar CPU_CORES=("${CPU_CORE_A}" "${CPU_CORE_B}" "${CPU_CORE_C}" "${CPU_CORE_D}")
declare -ar WORKER_LOGS=(
    "${RUN_DIR}/worker-A.log"
    "${RUN_DIR}/worker-B.log"
    "${RUN_DIR}/worker-C.log"
    "${RUN_DIR}/worker-D.log"
)

declare -a worker_pids=("" "" "" "")
declare -a worker_statuses=(1 1 1 1)

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
    echo "ERROR: do not run this experiment with sudo/root." >&2
    echo "Run it as the normal user after starting hailo_vctx_trace.sh separately." >&2
    exit 1
fi

cleanup()
{
    local exit_code=$?
    local pid

    trap - EXIT INT TERM
    for pid in "${worker_pids[@]}"; do
        if [[ -n "${pid}" ]] && kill -0 "${pid}" 2>/dev/null; then
            kill -TERM "${pid}" 2>/dev/null || true
        fi
    done
    stop_trace || true

    if (( exit_code != 0 )); then
        echo "Four-process experiment failed. Logs: ${RUN_DIR}" >&2
        for index in "${!WORKER_IDS[@]}"; do
            if [[ -f "${WORKER_LOGS[index]}" ]]; then
                echo "----- Worker ${WORKER_IDS[index]} tail -----" >&2
                tail -n 20 "${WORKER_LOGS[index]}" >&2 || true
            fi
        done
    fi
    exit "${exit_code}"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

require_file "multi_process executable" "${EXECUTABLE}"
if [[ ! -x "${EXECUTABLE}" ]]; then
    echo "ERROR: executable permission is missing: ${EXECUTABLE}" >&2
    exit 1
fi
if ! command -v timeout >/dev/null 2>&1; then
    echo "ERROR: GNU timeout is required to bound worker execution time." >&2
    exit 1
fi
if ! command -v taskset >/dev/null 2>&1; then
    echo "ERROR: taskset is required to pin each worker to a CPU core." >&2
    exit 1
fi

require_positive_integer "RESULT_TOP_K" "${RESULT_TOP_K}"
require_nonnegative_integer "RESULT_LOG_EVERY" "${RESULT_LOG_EVERY}"
require_positive_integer "READY_TIMEOUT_SECONDS" "${READY_TIMEOUT_SECONDS}"
require_positive_integer "RUN_TIMEOUT_SECONDS" "${RUN_TIMEOUT_SECONDS}"

declare -A seen_cpu_cores=()
for index in "${!WORKER_IDS[@]}"; do
    worker_id="${WORKER_IDS[index]}"
    require_file "worker ${worker_id} HEF" "${MODELS[index]}"
    require_file "worker ${worker_id} image" "${IMAGES[index]}"
    require_file "worker ${worker_id} labels" "${CLASS_LABELS[index]}"
    require_positive_integer "FRAME_COUNT_${worker_id}" "${FRAME_COUNTS[index]}"
    require_positive_integer "BATCH_SIZE_${worker_id}" "${BATCH_SIZES[index]}"
    require_nonnegative_integer "PRIORITY_${worker_id}" "${PRIORITIES[index]}"
    require_nonnegative_integer "SCHEDULER_TIMEOUT_MS_${worker_id}" "${SCHEDULER_TIMEOUTS_MS[index]}"
    require_nonnegative_integer "SCHEDULER_THRESHOLD_${worker_id}" "${SCHEDULER_THRESHOLDS[index]}"
    require_nonnegative_integer "CPU_CORE_${worker_id}" "${CPU_CORES[index]}"

    if [[ -n "${seen_cpu_cores[${CPU_CORES[index]}]+set}" ]]; then
        echo "ERROR: every worker must use a different CPU core; core ${CPU_CORES[index]} is duplicated." >&2
        exit 1
    fi
    seen_cpu_cores["${CPU_CORES[index]}"]=1
    if ! taskset --cpu-list "${CPU_CORES[index]}" true >/dev/null 2>&1; then
        echo "ERROR: worker ${worker_id} cannot be pinned to CPU core ${CPU_CORES[index]}." >&2
        echo "Set CPU_CORE_${worker_id} to an online core allowed for this process." >&2
        exit 1
    fi
done

mkdir -p "${BARRIER_DIR}"

vctx_quantum_ms="$(read_module_parameter "${VCTX_QUANTUM_MS_PARAMETER}")"
vctx_quantum_transfers="$(read_module_parameter "${VCTX_QUANTUM_TRANSFERS_PARAMETER}")"
{
    echo "run_id=${RUN_ID}"
    echo "mode=four-process-concurrent"
    echo "executable=${EXECUTABLE}"
    for index in "${!WORKER_IDS[@]}"; do
        worker_id="${WORKER_IDS[index]}"
        echo "worker_${worker_id}_model=${MODELS[index]}"
        echo "worker_${worker_id}_frames=${FRAME_COUNTS[index]}"
        echo "worker_${worker_id}_cpu_core=${CPU_CORES[index]}"
    done
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

echo "Launching four independent direct-mode processes on distinct CPU cores..."
for index in "${!WORKER_IDS[@]}"; do
    worker_id="${WORKER_IDS[index]}"
    echo "worker=${worker_id} cpu_core=${CPU_CORES[index]} log=${WORKER_LOGS[index]}"
    taskset --cpu-list "${CPU_CORES[index]}" \
        timeout --signal=TERM --kill-after=5s "${RUN_TIMEOUT_SECONDS}s" \
        env HAILO_RESULT_TOP_K="${RESULT_TOP_K}" \
        HAILO_RESULT_LOG_EVERY="${RESULT_LOG_EVERY}" \
        "${EXECUTABLE}" "${MODELS[index]}" "${IMAGES[index]}" "${CLASS_LABELS[index]}" \
        "${FRAME_COUNTS[index]}" "${BATCH_SIZES[index]}" "${PRIORITIES[index]}" \
        "${SCHEDULER_TIMEOUTS_MS[index]}" "${SCHEDULER_THRESHOLDS[index]}" \
        "${worker_id}" "${BARRIER_DIR}" >"${WORKER_LOGS[index]}" 2>&1 &
    worker_pids[index]=$!
done

readonly ready_deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
while true; do
    all_workers_ready=1
    for index in "${!WORKER_IDS[@]}"; do
        worker_id="${WORKER_IDS[index]}"
        if [[ ! -f "${BARRIER_DIR}/ready.${worker_id}" ]]; then
            all_workers_ready=0
        fi
        if ! kill -0 "${worker_pids[index]}" 2>/dev/null; then
            echo "ERROR: worker ${worker_id} exited before reaching the start barrier." >&2
            exit 1
        fi
    done
    if (( all_workers_ready != 0 )); then
        break
    fi
    if (( SECONDS >= ready_deadline )); then
        echo "ERROR: all four workers did not become ready within ${READY_TIMEOUT_SECONDS}s." >&2
        exit 1
    fi
    sleep 0.05
done

# Publish one marker only after A-D have all initialized their device, model,
# and VStreams. Rename makes the release atomic for every waiting process.
printf 'release_unix_ms=%s\n' "$(date +%s%3N)" >"${BARRIER_DIR}/start.tmp"
mv "${BARRIER_DIR}/start.tmp" "${BARRIER_DIR}/start"
echo "All four workers ready; inference barrier released."

for index in "${!WORKER_IDS[@]}"; do
    if wait "${worker_pids[index]}"; then
        worker_statuses[index]=0
    else
        worker_statuses[index]=$?
    fi
    worker_pids[index]=""
done

stop_trace

print_worker_results()
{
    local worker_id=$1
    local worker_log=$2

    echo "----- Worker ${worker_id} inference results -----"
    if ! grep -E 'inference-(result-(topk|summary)|score-validation)' "${worker_log}"; then
        echo "No decoded inference result was recorded for worker ${worker_id}."
    fi
}

{
    for index in "${!WORKER_IDS[@]}"; do
        print_worker_results "${WORKER_IDS[index]}" "${WORKER_LOGS[index]}"
    done
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

declare -a starts=("" "" "" "")
declare -a ends=("" "" "" "")
declare -a input_streams=("" "" "" "")
declare -a output_streams=("" "" "" "")
declare -a score_validation_failures=(0 0 0 0)
declare -a classification_passes=(0 0 0 0)
declare -a classification_failures=(0 0 0 0)

timing_complete=1
overlap_start=0
overlap_end=0
for index in "${!WORKER_IDS[@]}"; do
    starts[index]="$(extract_last_value start_unix_ms "${WORKER_LOGS[index]}" || true)"
    ends[index]="$(extract_last_value end_unix_ms "${WORKER_LOGS[index]}" || true)"
    input_streams[index]="$(extract_configuration_value inputs "${WORKER_LOGS[index]}" || true)"
    output_streams[index]="$(extract_configuration_value outputs "${WORKER_LOGS[index]}" || true)"
    score_validation_failures[index]="$(grep -c 'inference-result-summary.*score_validation=FAIL' "${WORKER_LOGS[index]}" || true)"
    classification_passes[index]="$(grep -c 'inference-result-summary.*classification_result=PASS' "${WORKER_LOGS[index]}" || true)"
    classification_failures[index]="$(grep -c 'inference-result-summary.*classification_result=FAIL' "${WORKER_LOGS[index]}" || true)"

    if [[ ! "${starts[index]}" =~ ^[0-9]+$ || ! "${ends[index]}" =~ ^[0-9]+$ ]]; then
        timing_complete=0
        continue
    fi
    if (( index == 0 || starts[index] > overlap_start )); then
        overlap_start="${starts[index]}"
    fi
    if (( index == 0 || ends[index] < overlap_end )); then
        overlap_end="${ends[index]}"
    fi
done

overlap_ms=0
if (( timing_complete != 0 && overlap_end > overlap_start )); then
    overlap_ms=$((overlap_end - overlap_start))
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
if [[ "${ENABLE_VCTX_TRACE}" == "1" ]]; then
    trace_result="PASS"
    if [[ -f "${TRACE_LOG}" ]]; then
        all_stream_counts_valid=1
        for index in "${!WORKER_IDS[@]}"; do
            if [[ "${input_streams[index]}" =~ ^[1-9][0-9]*$ &&
                  "${output_streams[index]}" =~ ^[1-9][0-9]*$ ]]; then
                trace_expected_transfer_count=$((
                    trace_expected_transfer_count +
                    FRAME_COUNTS[index] * (input_streams[index] + output_streams[index])
                ))
            else
                all_stream_counts_valid=0
            fi
        done
        if (( all_stream_counts_valid == 0 )); then
            trace_expected_transfer_count=0
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
    else
        trace_result="FAIL"
    fi
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

transport_result="PASS"
classification_result="PASS"
for index in "${!WORKER_IDS[@]}"; do
    if (( worker_statuses[index] != 0 )) ||
       ! grep -q 'inference-transport-complete status=0' "${WORKER_LOGS[index]}"; then
        transport_result="FAIL"
    fi
    if (( classification_passes[index] == 0 || classification_failures[index] != 0 )); then
        classification_result="FAIL"
    fi
done
if (( cursor_rebase_failure_count != 0 || stall_warning_count != 0 || overlap_ms <= 0 )); then
    transport_result="FAIL"
fi
if [[ "${ENABLE_VCTX_TRACE}" == "1" ]] && (( vctx_count < 4 )); then
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
    echo "score_result=${classification_result}"
    for index in "${!WORKER_IDS[@]}"; do
        worker_id="${WORKER_IDS[index]}"
        echo "worker_${worker_id}_exit=${worker_statuses[index]}"
        echo "worker_${worker_id}_cpu_core=${CPU_CORES[index]}"
        echo "worker_${worker_id}_interval_ms=${starts[index]:-unknown}..${ends[index]:-unknown}"
        echo "worker_${worker_id}_score_validation_failures=${score_validation_failures[index]}"
        echo "worker_${worker_id}_classification_failures=${classification_failures[index]}"
        echo "worker_${worker_id}_log=${WORKER_LOGS[index]}"
    done
    echo "four_worker_overlap_ms=${overlap_ms}"
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
    echo "inference_results_log=${RESULTS_LOG}"
    if [[ "${ENABLE_VCTX_TRACE}" == "1" ]]; then
        echo "dmesg_log=${TRACE_LOG}"
        echo "dmesg_reader_log=${TRACE_READER_LOG}"
    fi
} | tee "${SUMMARY_LOG}"

if [[ "${result}" != "PASS" ]]; then
    echo "Four-process concurrent verification failed; inspect ${RUN_DIR}." >&2
    exit 1
fi

echo "Four-process concurrent verification passed. Logs: ${RUN_DIR}"
