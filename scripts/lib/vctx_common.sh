#!/usr/bin/env bash

# Shared helpers for the VCTX experiment runners.
#
# The functions intentionally use variables owned by the caller, such as
# EXTERNAL_TRACE_STATE_FILE, TRACE_LOG, and RUN_DIR. This keeps the runner
# configuration in one place while avoiding a second configuration layer.

read_external_state_value()
{
    local key=$1

    sed -n "s/^${key}=//p" "${EXTERNAL_TRACE_STATE_FILE}" 2>/dev/null | head -n 1
}

prepare_external_trace()
{
    local trace_format_version

    if [[ ! -r "${EXTERNAL_TRACE_STATE_FILE}" ]]; then
        echo "ERROR: external VCTX trace is not running." >&2
        echo "Start hailo_vctx_trace.sh in another terminal first." >&2
        echo "Expected state file: ${EXTERNAL_TRACE_STATE_FILE}" >&2
        return 1
    fi

    trace_format_version="$(read_external_state_value format_version)"
    external_trace_pid="$(read_external_state_value pid)"
    external_trace_producer_pid="$(read_external_state_value producer_pid)"
    external_trace_log="$(read_external_state_value log)"
    external_trace_error_log="$(read_external_state_value error_log)"
    if [[ "${trace_format_version}" != "2" ]]; then
        echo "ERROR: incompatible VCTX trace helper format: ${trace_format_version:-legacy}" >&2
        echo "Stop and restart the updated hailo_vctx_trace.sh before running this experiment." >&2
        return 1
    fi
    if [[ ! "${external_trace_pid}" =~ ^[1-9][0-9]*$ ]] ||
       ! kill -0 "${external_trace_pid}" 2>/dev/null; then
        echo "ERROR: external VCTX trace state is stale: ${EXTERNAL_TRACE_STATE_FILE}" >&2
        return 1
    fi
    if [[ ! "${external_trace_producer_pid}" =~ ^[1-9][0-9]*$ ]] ||
       ! kill -0 "${external_trace_producer_pid}" 2>/dev/null; then
        echo "ERROR: external dmesg reader is not running: pid=${external_trace_producer_pid:-unknown}" >&2
        return 1
    fi
    if [[ -z "${external_trace_log}" || ! -r "${external_trace_log}" ||
          -z "${external_trace_error_log}" || ! -r "${external_trace_error_log}" ]]; then
        echo "ERROR: external VCTX trace log is unavailable: ${external_trace_log:-unknown}" >&2
        return 1
    fi

    external_trace_start_line="$(wc -l <"${external_trace_log}")"
    external_trace_error_start_line="$(wc -l <"${external_trace_error_log}")"
    external_trace_active=1
    echo "Using external VCTX trace: pid=${external_trace_pid} reader_pid=${external_trace_producer_pid} log=${external_trace_log} start_line=${external_trace_start_line}"
}

capture_external_trace()
{
    local end_line
    local error_end_line
    local error_first_line
    local capture_first_line

    if (( external_trace_active == 0 || external_trace_captured != 0 )); then
        return
    fi
    if ! kill -0 "${external_trace_pid}" 2>/dev/null; then
        echo "ERROR: external VCTX trace stopped during the experiment: pid=${external_trace_pid}" >&2
        external_trace_capture_status=1
    fi
    if ! kill -0 "${external_trace_producer_pid}" 2>/dev/null; then
        echo "ERROR: external dmesg reader stopped during the experiment: pid=${external_trace_producer_pid}" >&2
        external_trace_capture_status=1
    fi
    sleep 0.5
    end_line="$(wc -l <"${external_trace_log}")"
    if (( end_line < external_trace_start_line )); then
        echo "ERROR: external trace log was truncated during the experiment." >&2
        capture_first_line=1
        external_trace_capture_status=1
    else
        capture_first_line=$((external_trace_start_line + 1))
    fi
    awk -v first="${capture_first_line}" -v last="${end_line}" \
        'NR >= first && NR <= last && /vctx-(trace|fw)/ { print }' \
        "${external_trace_log}" >"${TRACE_LOG}"

    error_end_line="$(wc -l <"${external_trace_error_log}")"
    if (( error_end_line < external_trace_error_start_line )); then
        echo "ERROR: external dmesg reader error log was truncated." >&2
        error_first_line=1
        external_trace_capture_status=1
    else
        error_first_line=$((external_trace_error_start_line + 1))
    fi
    if (( error_end_line >= error_first_line )); then
        sed -n "${error_first_line},${error_end_line}p" \
            "${external_trace_error_log}" >"${TRACE_READER_LOG}"
    else
        : >"${TRACE_READER_LOG}"
    fi
    if [[ -s "${TRACE_READER_LOG}" ]]; then
        echo "ERROR: dmesg reader reported errors; see ${TRACE_READER_LOG}." >&2
        external_trace_capture_status=1
    fi
    external_trace_captured=1
    return 0
}

stop_trace()
{
    capture_external_trace
}

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

read_module_parameter()
{
    local path=$1

    if [[ -r "${path}" ]]; then
        cat "${path}" 2>/dev/null || echo "unavailable"
    else
        echo "unavailable"
    fi
}
