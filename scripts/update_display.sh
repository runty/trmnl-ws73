#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${TRMNL_ENV_FILE:-${PROJECT_DIR}/trmnl-ws73.env}"

log() {
    printf '[%s] %s\n' "$(date -Is)" "$*"
}

# Tell an Uptime Kuma push monitor that a run succeeded; Kuma alerts when the
# pushes stop. Failures here never change the run's exit status.
send_heartbeat() {
    [ -n "${HEARTBEAT_URL}" ] || return 0
    local resolve_args=()
    if [ -n "${HEARTBEAT_RESOLVE}" ]; then
        resolve_args=(--resolve "${HEARTBEAT_RESOLVE}")
    fi
    if ! curl -fsS -o /dev/null --max-time 15 "${resolve_args[@]}" -G \
        --data-urlencode "status=up" \
        --data-urlencode "msg=$1" \
        --data-urlencode "ping=$2" \
        "${HEARTBEAT_URL}"; then
        log "WARNING: heartbeat push failed."
    fi
}

if [ -r "${ENV_FILE}" ]; then
    set -a
    # shellcheck disable=SC1090
    . "${ENV_FILE}"
    set +a
fi

# Read settings after the env file so values set there (cron passes none) apply.
LOCK_FILE="${TRMNL_LOCK_FILE:-${PROJECT_DIR}/update_display.lock}"
RUN_TIMEOUT="${TRMNL_RUN_TIMEOUT:-780s}"
PYTHON_BIN="${PYTHON_BIN:-python3}"
HEARTBEAT_URL="${TRMNL_HEARTBEAT_URL:-}"
HEARTBEAT_RESOLVE="${TRMNL_HEARTBEAT_RESOLVE:-}"

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    log "Another display update is still running; skipping this cycle."
    exit 0
fi

start_ts="$(date +%s)"
log "Starting display update."

set +e
timeout --kill-after=30s "${RUN_TIMEOUT}" "${PYTHON_BIN}" -u "${SCRIPT_DIR}/update_display.py"
status="$?"

elapsed="$(( $(date +%s) - start_ts ))"
if [ "${status}" -eq 0 ]; then
    log "Finished display update in ${elapsed}s."
    send_heartbeat "OK" "$((elapsed * 1000))"
elif [ "${status}" -eq 124 ] || [ "${status}" -eq 137 ]; then
    log "ERROR: display update timed out after ${RUN_TIMEOUT}; exit status ${status}."
else
    log "ERROR: display update failed after ${elapsed}s; exit status ${status}."
fi
exit "${status}"
