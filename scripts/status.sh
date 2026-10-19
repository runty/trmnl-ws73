#!/bin/bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_FILE="${TRMNL_LOG_FILE:-${PROJECT_DIR}/cron.log}"
CACHE_FILE="${TRMNL_CACHE_FILE:-${PROJECT_DIR}/last_image.txt}"
SINCE="${1:-2 hours ago}"

section() {
    printf '\n== %s ==\n' "$1"
}

run_optional() {
    if command -v "$1" >/dev/null 2>&1; then
        "$@"
    else
        printf '%s not installed\n' "$1"
    fi
}

section "System"
hostname
date
uptime
free -h
df -h / "${PROJECT_DIR}" 2>/dev/null || true
systemctl --failed --no-pager 2>/dev/null || true

section "Updater Processes"
pgrep -af "update_display|python3|timeout" || true

section "Display State"
if [ -f "${CACHE_FILE}" ]; then
    printf 'last slide ETag: '
    cat "${CACHE_FILE}"
    printf '\n'
    stat -c '%y %n' "${CACHE_FILE}" 2>/dev/null || stat "${CACHE_FILE}" 2>/dev/null
else
    printf 'cache file missing: %s\n' "${CACHE_FILE}"
fi

section "Update Log"
if [ -f "${LOG_FILE}" ]; then
    tail -80 "${LOG_FILE}"
else
    printf 'log file missing: %s\n' "${LOG_FILE}"
fi

section "Network"
curl -sS -o /dev/null -w 'WadsFrame health: HTTP %{http_code} in %{time_total}s\n' --max-time 15 \
    "${WADSFRAME_HEALTH_URL:-http://192.168.22.102:3200/api/health}" || true
if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show wlan0 2>/dev/null || true
    wifi_connection="$(nmcli -g GENERAL.CONNECTION device show wlan0 2>/dev/null)"
    if [ -n "${wifi_connection}" ]; then
        nmcli -f 802-11-wireless.powersave,connection.autoconnect-retries \
            connection show "${wifi_connection}" 2>/dev/null || true
    fi
fi

section "Recent Wi-Fi Events"
journalctl -b --since "${SINCE}" --no-pager 2>/dev/null \
    | grep -Ei "NetworkManager|wlan0|wpa_supplicant|brcmf|DNS|dhcp|link timed|Activation|deauth|disconnect|connect" \
    | tail -160 || true

section "Network Watchdog"
systemctl list-timers trmnl-network-watchdog.timer --no-pager 2>/dev/null || true
journalctl -t trmnl-network-watchdog --since "${SINCE}" --no-pager 2>/dev/null | tail -40 || true

section "Hardware"
run_optional vcgencmd measure_temp
run_optional vcgencmd get_throttled
