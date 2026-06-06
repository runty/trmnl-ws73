#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${TRMNL_ENV_FILE:-${SCRIPT_DIR}/trmnl-ws73.env}"
LOCK_FILE="${TRMNL_LOCK_FILE:-${SCRIPT_DIR}/update_display.lock}"
RUN_TIMEOUT="${TRMNL_RUN_TIMEOUT:-780s}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

log() {
    printf '[%s] %s\n' "$(date -Is)" "$*"
}

if [ -r "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
    set +a
fi

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "Another TRMNL update is still running; skipping this cycle."
    exit 0
fi

start_ts="$(date +%s)"
log "Starting TRMNL display update."

set +e
timeout --kill-after=30s "${RUN_TIMEOUT}" "${PYTHON_BIN}" -u "${SCRIPT_DIR}/update_display.py"
status="$?"
set -e

elapsed="$(( $(date +%s) - start_ts ))"
if [ "${status}" -eq 0 ]; then
    log "Finished TRMNL display update in ${elapsed}s."
elif [ "${status}" -eq 124 ] || [ "${status}" -eq 137 ]; then
    log "ERROR: TRMNL display update timed out after ${RUN_TIMEOUT}; exit status ${status}."
else
    log "ERROR: TRMNL display update failed after ${elapsed}s; exit status ${status}."
fi
exit "${status}"
