#!/bin/bash
# Recover the Pi's Wi-Fi when it silently drops off the network.
#
# Runs as root from trmnl-network-watchdog.timer. Each run checks whether
# WadsFrame on Shrimp answers; consecutive failures escalate:
#   TRMNL_WATCHDOG_RECONNECT_AFTER  failures -> re-activate the NM connection
#   TRMNL_WATCHDOG_RADIO_AFTER      failures -> toggle the Wi-Fi radio
#   TRMNL_WATCHDOG_REBOOT_AFTER     failures -> reboot (rate limited)
#
# TRMNL_WATCHDOG_DRY_RUN=1 logs each recovery step instead of running it.
# TRMNL_WATCHDOG_GATEWAY overrides the gateway to ping; with an unreachable
# address such as 192.0.2.1 and a dry run, the escalation can be tested safely.
set -u

CHECK_URL="${TRMNL_WATCHDOG_URL:-http://192.168.22.102:3200/api/health}"
WIFI_DEVICE="${TRMNL_WATCHDOG_DEVICE:-wlan0}"
RECONNECT_AFTER="${TRMNL_WATCHDOG_RECONNECT_AFTER:-2}"
RADIO_AFTER="${TRMNL_WATCHDOG_RADIO_AFTER:-4}"
REBOOT_AFTER="${TRMNL_WATCHDOG_REBOOT_AFTER:-12}"
REBOOT_MIN_INTERVAL="${TRMNL_WATCHDOG_REBOOT_MIN_INTERVAL:-21600}"
STATE_FILE="${TRMNL_WATCHDOG_STATE:-/run/trmnl-network-watchdog.failures}"
REBOOT_STAMP="${TRMNL_WATCHDOG_REBOOT_STAMP:-/var/lib/trmnl-network-watchdog/last-reboot}"
DRY_RUN="${TRMNL_WATCHDOG_DRY_RUN:-0}"

log() {
    printf '%s\n' "$*"
    logger -t trmnl-network-watchdog -- "$*" 2>/dev/null || true
}

act() {
    if [ "${DRY_RUN}" = "1" ]; then
        log "DRY RUN: would run: $*"
        return 0
    fi
    "$@"
}

healthy() {
    timeout 20 curl -fsS -o /dev/null --max-time 15 "${CHECK_URL}" >/dev/null 2>&1
}

gateway() {
    if [ -n "${TRMNL_WATCHDOG_GATEWAY:-}" ]; then
        printf '%s\n' "${TRMNL_WATCHDOG_GATEWAY}"
        return
    fi
    ip -4 route show default dev "${WIFI_DEVICE}" 2>/dev/null | awk '/default/ {print $3; exit}'
}

failures=0
if [ -r "${STATE_FILE}" ]; then
    failures="$(cat "${STATE_FILE}" 2>/dev/null || echo 0)"
    case "${failures}" in ''|*[!0-9]*) failures=0 ;; esac
fi

if healthy; then
    if [ "${failures}" -gt 0 ]; then
        log "Network recovered after ${failures} failed check(s)."
    fi
    rm -f "${STATE_FILE}"
    exit 0
fi

gw="$(gateway)"
if [ -n "${gw}" ] && ping -c 1 -W 3 "${gw}" >/dev/null 2>&1; then
    # The LAN link is up; Shrimp or WadsFrame is the problem, and bouncing
    # Wi-Fi will not fix it. Log it without escalating.
    log "Cannot reach ${CHECK_URL}, but gateway ${gw} answers; not touching Wi-Fi."
    rm -f "${STATE_FILE}"
    exit 0
fi

failures="$((failures + 1))"
printf '%s\n' "${failures}" > "${STATE_FILE}"
log "Network check failed (${failures} in a row): ${CHECK_URL} and gateway '${gw:-none}' unreachable."

if [ "${failures}" -ge "${REBOOT_AFTER}" ]; then
    now="$(date +%s)"
    last=0
    [ -r "${REBOOT_STAMP}" ] && last="$(cat "${REBOOT_STAMP}" 2>/dev/null || echo 0)"
    case "${last}" in ''|*[!0-9]*) last=0 ;; esac
    if [ "$((now - last))" -ge "${REBOOT_MIN_INTERVAL}" ]; then
        log "Rebooting to recover Wi-Fi."
        if [ "${DRY_RUN}" != "1" ]; then
            mkdir -p "$(dirname "${REBOOT_STAMP}")"
            printf '%s\n' "${now}" > "${REBOOT_STAMP}"
            sync
        fi
        act systemctl reboot
        exit 0
    fi
    log "Reboot skipped; last watchdog reboot was $((now - last))s ago."
fi

if [ "${failures}" -ge "${RADIO_AFTER}" ]; then
    log "Toggling the Wi-Fi radio."
    act timeout 30 nmcli radio wifi off
    act sleep 5
    act timeout 30 nmcli radio wifi on
elif [ "${failures}" -ge "${RECONNECT_AFTER}" ]; then
    log "Re-activating Wi-Fi on ${WIFI_DEVICE}."
    act timeout 30 nmcli device set "${WIFI_DEVICE}" autoconnect yes || true
    act timeout 60 nmcli device connect "${WIFI_DEVICE}" || true
fi
exit 0
