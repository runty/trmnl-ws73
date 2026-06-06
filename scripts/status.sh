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

section "TRMNL Processes"
pgrep -af "update_display|trmnl|python3|timeout" || true

section "TRMNL State"
if [ -f "${CACHE_FILE}" ]; then
    printf 'last image: '
    cat "${CACHE_FILE}"
    printf '\n'
    stat -c '%y %n' "${CACHE_FILE}" 2>/dev/null || stat "${CACHE_FILE}" 2>/dev/null
else
    printf 'cache file missing: %s\n' "${CACHE_FILE}"
fi

section "TRMNL Log"
if [ -f "${LOG_FILE}" ]; then
    tail -80 "${LOG_FILE}"
else
    printf 'log file missing: %s\n' "${LOG_FILE}"
fi

section "Network"
getent hosts usetrmnl.com || true
python3 - <<'PY'
import urllib.request

try:
    with urllib.request.urlopen("https://usetrmnl.com", timeout=10) as response:
        print("https://usetrmnl.com", response.status)
except Exception as e:
    print("https://usetrmnl.com error", repr(e))
PY
if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f GENERAL.STATE,GENERAL.CONNECTION,IP4.ADDRESS,IP4.GATEWAY,IP4.DNS device show wlan0 2>/dev/null || true
    nmcli -f 802-11-wireless.powersave connection show netplan-wlan0-pw24 2>/dev/null || true
fi

section "Recent Wi-Fi Events"
journalctl -b --since "${SINCE}" --no-pager 2>/dev/null \
    | egrep -i "NetworkManager|wlan0|wpa_supplicant|brcmf|DNS|dhcp|link timed|Activation|deauth|disconnect|connect" \
    | tail -160 || true

section "Hardware"
run_optional vcgencmd measure_temp
run_optional vcgencmd get_throttled
