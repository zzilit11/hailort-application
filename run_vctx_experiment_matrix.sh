#!/bin/bash

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly DUAL_RUNNER="${DUAL_RUNNER:-${SCRIPT_DIR}/run_inference_multi.sh}"
readonly SINGLE_RUNNER="${SINGLE_RUNNER:-${SCRIPT_DIR}/run_inference_single_control.sh}"
readonly TRACE_HELPER="${TRACE_HELPER:-${SCRIPT_DIR}/../hailort-drivers/linux/pcie/tools/hailo_vctx_trace.sh}"
readonly MATRIX_ROOT="${MATRIX_ROOT:-${SCRIPT_DIR}/logs}"
readonly MATRIX_ID="$(date +'%Y%m%d-%H%M%S')-$$"
readonly MATRIX_DIR="${MATRIX_ROOT}/vctx-matrix-${MATRIX_ID}"
readonly RUN_LONG_MULTI="${RUN_LONG_MULTI:-1}"
readonly CASE_RUN_TIMEOUT_SECONDS="${CASE_RUN_TIMEOUT_SECONDS:-90}"
readonly ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE:-1}"

declare -a case_names=()
declare -a case_statuses=()

if (( EUID == 0 )); then
    echo "ERROR: do not run the experiment matrix with sudo/root." >&2
    echo "Run it as the normal user; only the trace helper uses limited sudo commands." >&2
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

[[ -x "${DUAL_RUNNER}" ]] || { echo "ERROR: dual runner is not executable: ${DUAL_RUNNER}" >&2; exit 1; }
[[ -x "${SINGLE_RUNNER}" ]] || { echo "ERROR: single runner is not executable: ${SINGLE_RUNNER}" >&2; exit 1; }
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
    [[ -x "${TRACE_HELPER}" ]] || { echo "ERROR: trace helper is not executable: ${TRACE_HELPER}" >&2; exit 1; }
    echo "Authorizing VCTX trace access once before running the matrix..."
    "${TRACE_HELPER}" --authorize
fi

# Case 1 proves that initialization and short inter-process switching still
# work before either H2D descriptor ring approaches its first wrap.
run_case "dual-40" env \
    FRAME_COUNT=40 \
    RUN_TIMEOUT_SECONDS="${CASE_RUN_TIMEOUT_SECONDS}" \
    ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE}" \
    VCTX_TRACE_PREAUTHORIZED="${ENABLE_VCTX_TRACE}" \
    TRACE_HELPER="${TRACE_HELPER}" \
    RUN_ROOT="${MATRIX_DIR}/dual-40" \
    "${DUAL_RUNNER}"

# Case 2 distinguishes a generic descriptor-ring wrap defect from a defect
# introduced by VCTX switching.  The same worker runs without a file barrier.
run_case "single-200" env \
    FRAME_COUNT=200 \
    RUN_TIMEOUT_SECONDS="${CASE_RUN_TIMEOUT_SECONDS}" \
    ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE}" \
    VCTX_TRACE_PREAUTHORIZED="${ENABLE_VCTX_TRACE}" \
    TRACE_HELPER="${TRACE_HELPER}" \
    RUN_ROOT="${MATRIX_DIR}/single-200" \
    "${SINGLE_RUNNER}"

# Case 3 reproduces the long two-process workload with cursor/ring/stall
# diagnostics enabled.  It may be skipped while iterating on shorter tests.
if [[ "${RUN_LONG_MULTI}" == "1" ]]; then
    run_case "dual-200" env \
        FRAME_COUNT=200 \
        RUN_TIMEOUT_SECONDS="${CASE_RUN_TIMEOUT_SECONDS}" \
        ENABLE_VCTX_TRACE="${ENABLE_VCTX_TRACE}" \
        VCTX_TRACE_PREAUTHORIZED="${ENABLE_VCTX_TRACE}" \
        TRACE_HELPER="${TRACE_HELPER}" \
        RUN_ROOT="${MATRIX_DIR}/dual-200" \
        "${DUAL_RUNNER}"
fi

overall_status=0
for index in "${!case_names[@]}"; do
    if (( case_statuses[index] != 0 )); then
        overall_status=1
    fi
done

{
    echo "matrix_id=${MATRIX_ID}"
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
