#!/bin/bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly APP_DIR="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
readonly DUAL_RUNNER="${DUAL_RUNNER:-${APP_DIR}/scripts/run/run_inference_multi.sh}"
readonly SINGLE_RUNNER="${SINGLE_RUNNER:-${APP_DIR}/scripts/run/run_inference_single_control.sh}"
readonly MATRIX_ROOT="${MATRIX_ROOT:-${APP_DIR}/logs}"
readonly MATRIX_ID="$(date +'%Y%m%d-%H%M%S')-$$"
readonly MATRIX_DIR="${MATRIX_ROOT}/vctx-matrix-${MATRIX_ID}"
readonly RUN_LONG_MULTI="${RUN_LONG_MULTI:-1}"
readonly CASE_RUN_TIMEOUT_SECONDS="${CASE_RUN_TIMEOUT_SECONDS:-90}"
readonly ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE:-1}"
readonly VCTX_TRACE_SESSION_UID="$(id -u)"
readonly EXTERNAL_TRACE_STATE_FILE="${HAILO_VCTX_TRACE_STATE_FILE:-/tmp/hailo-vctx-trace-${VCTX_TRACE_SESSION_UID}.state}"

declare -a case_names=()
declare -a case_statuses=()

if (( EUID == 0 )); then
    echo "ERROR: do not run the experiment matrix with sudo/root." >&2
    echo "Start hailo_vctx_trace.sh separately, then run this matrix as the normal user." >&2
    exit 1
fi

run_case()
{
    local case_name=$1
    shift
    local console_log="${MATRIX_DIR}/${case_name}.console.log"
    local status

    echo "===== ${case_name} ====="
    set +e
    "$@" 2>&1 | tee "${console_log}"
    status=${PIPESTATUS[0]}
    set -e
    case_names+=("${case_name}")
    case_statuses+=("${status}")
    echo "case=${case_name} exit=${status}"
}

[[ -f "${DUAL_RUNNER}" ]] || { echo "ERROR: dual runner not found: ${DUAL_RUNNER}" >&2; exit 1; }
[[ -f "${SINGLE_RUNNER}" ]] || { echo "ERROR: single runner not found: ${SINGLE_RUNNER}" >&2; exit 1; }
if [[ "${RUN_LONG_MULTI}" != "0" && "${RUN_LONG_MULTI}" != "1" ]]; then
    echo "ERROR: RUN_LONG_MULTI must be 0 or 1." >&2
    exit 1
fi
if [[ "${ENABLE_VCTX_TRACE}" != "0" && "${ENABLE_VCTX_TRACE}" != "1" ]]; then
    echo "ERROR: ENABLE_VCTX_TRACE must be 0 or 1." >&2
    exit 1
fi
if [[ ! "${CASE_RUN_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: CASE_RUN_TIMEOUT_SECONDS must be a positive integer." >&2
    exit 1
fi

mkdir -p "${MATRIX_DIR}"

if [[ "${ENABLE_VCTX_TRACE}" == "1" ]]; then
    if [[ ! -r "${EXTERNAL_TRACE_STATE_FILE}" ]]; then
        echo "ERROR: external VCTX trace is not running." >&2
        echo "Run hailo_vctx_trace.sh in another terminal first." >&2
        echo "Expected state file: ${EXTERNAL_TRACE_STATE_FILE}" >&2
        exit 1
    fi
    external_trace_format_version="$(sed -n 's/^format_version=//p' "${EXTERNAL_TRACE_STATE_FILE}" | head -n 1)"
    external_trace_pid="$(sed -n 's/^pid=//p' "${EXTERNAL_TRACE_STATE_FILE}" | head -n 1)"
    external_trace_producer_pid="$(sed -n 's/^producer_pid=//p' "${EXTERNAL_TRACE_STATE_FILE}" | head -n 1)"
    external_trace_log="$(sed -n 's/^log=//p' "${EXTERNAL_TRACE_STATE_FILE}" | head -n 1)"
    external_trace_error_log="$(sed -n 's/^error_log=//p' "${EXTERNAL_TRACE_STATE_FILE}" | head -n 1)"
    if [[ "${external_trace_format_version}" != "2" ]]; then
        echo "ERROR: incompatible VCTX trace helper format: ${external_trace_format_version:-legacy}" >&2
        echo "Stop and restart the updated hailo_vctx_trace.sh before running this matrix." >&2
        exit 1
    fi
    if [[ ! "${external_trace_pid}" =~ ^[1-9][0-9]*$ ]] ||
       ! kill -0 "${external_trace_pid}" 2>/dev/null; then
        echo "ERROR: external VCTX trace state is stale: ${EXTERNAL_TRACE_STATE_FILE}" >&2
        exit 1
    fi
    if [[ ! "${external_trace_producer_pid}" =~ ^[1-9][0-9]*$ ]] ||
       ! kill -0 "${external_trace_producer_pid}" 2>/dev/null; then
        echo "ERROR: external dmesg reader is not running: pid=${external_trace_producer_pid:-unknown}" >&2
        exit 1
    fi
    if [[ -z "${external_trace_log}" || ! -r "${external_trace_log}" ||
          -z "${external_trace_error_log}" || ! -r "${external_trace_error_log}" ]]; then
        echo "ERROR: external VCTX trace log is unavailable: ${external_trace_log:-unknown}" >&2
        exit 1
    fi
    if [[ -s "${external_trace_error_log}" ]]; then
        echo "ERROR: external dmesg reader already reported errors: ${external_trace_error_log}" >&2
        exit 1
    fi
    echo "Using independently running VCTX trace: pid=${external_trace_pid} reader_pid=${external_trace_producer_pid} log=${external_trace_log}"
fi

# Case 1 proves that initialization and short inter-process switching still
# work before either H2D descriptor ring approaches its first wrap.
run_case "dual-40" env \
    FRAME_COUNT=40 \
    RUN_TIMEOUT_SECONDS="${CASE_RUN_TIMEOUT_SECONDS}" \
    ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE}" \
    HAILO_VCTX_TRACE_STATE_FILE="${EXTERNAL_TRACE_STATE_FILE}" \
    RUN_ROOT="${MATRIX_DIR}/dual-40" \
    bash "${DUAL_RUNNER}"

# Case 2 distinguishes a generic descriptor-ring wrap defect from a defect
# introduced by VCTX switching.  The same worker runs without a file barrier.
run_case "single-200" env \
    FRAME_COUNT=200 \
    RUN_TIMEOUT_SECONDS="${CASE_RUN_TIMEOUT_SECONDS}" \
    ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE}" \
    HAILO_VCTX_TRACE_STATE_FILE="${EXTERNAL_TRACE_STATE_FILE}" \
    RUN_ROOT="${MATRIX_DIR}/single-200" \
    bash "${SINGLE_RUNNER}"

# Case 3 reproduces the long two-process workload with cursor/ring/stall
# diagnostics enabled.  It may be skipped while iterating on shorter tests.
if [[ "${RUN_LONG_MULTI}" == "1" ]]; then
    run_case "dual-200" env \
        FRAME_COUNT=200 \
        RUN_TIMEOUT_SECONDS="${CASE_RUN_TIMEOUT_SECONDS}" \
        ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE}" \
        HAILO_VCTX_TRACE_STATE_FILE="${EXTERNAL_TRACE_STATE_FILE}" \
        RUN_ROOT="${MATRIX_DIR}/dual-200" \
        bash "${DUAL_RUNNER}"
fi

overall_status=0
for index in "${!case_names[@]}"; do
    if (( case_statuses[index] != 0 )); then
        overall_status=1
    fi
done

{
    echo "matrix_id=${MATRIX_ID}"
    echo "vctx_trace_mode=external"
    echo "external_trace_state_file=${EXTERNAL_TRACE_STATE_FILE}"
    for index in "${!case_names[@]}"; do
        echo "${case_names[index]}_exit=${case_statuses[index]}"
    done
    echo "result=$([[ ${overall_status} -eq 0 ]] && echo PASS || echo FAIL)"
    echo "logs=${MATRIX_DIR}"
} | tee "${MATRIX_DIR}/summary.txt"

if (( overall_status != 0 )); then
    echo "One or more VCTX experiment cases failed. Logs: ${MATRIX_DIR}" >&2
    exit 1
fi

echo "All VCTX experiment cases passed. Logs: ${MATRIX_DIR}"
