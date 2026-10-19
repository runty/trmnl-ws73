# trmnl-ws73

E-ink photo frame client for ws73, a Raspberry Pi Zero W driving a Waveshare
7.3 inch Spectra 6 e-paper display (800×480, six colours, about 30 seconds per
full refresh).

ws73 shows photo slides from [WadsFrame](https://github.com/runty/wadsframe), the
homelab display server on Shrimp: the same Google Photos albums, smart crops and
collages as the Lenovo Smart Frame, changing hourly, with no clock. WadsFrame
renders and dithers each slide to the panel's six inks; the Pi only fetches the
PNG and draws it. Scene, album, slide time, next/previous and pause are Home
Assistant controls on the WadsFrame device (`ws73 …` entities).

Until 2026-10-19 this was a [TRMNL](https://usetrmnl.com) BYOD client; the TRMNL
licence moved to a XIAO ESP32-C3 with a 7.5" panel. The `TRMNL_` prefix on
settings, the repository name and the watchdog's unit names are left from then.
It is separate from the Pico W / Pimoroni Inky Frame MicroPython client in
`trmnlframe`.

## What It Does

- Polls `WADSFRAME_URL` (`/api/displays/ws73/eink.png`) with the last slide's
  `ETag`; WadsFrame answers `304` until the slide changes, which it does at the
  first poll after each hour.
- Renders a new slide through Waveshare's `epd7in3e` Python driver. The PNG is
  already in the driver's six colours, so the driver's own quantising changes
  nothing.
- Runs from cron every 15 minutes and once after boot.
- Redraws an unchanged image after 12 hours, and treats a panel refresh that
  finishes in under 10 seconds as a failed draw, so a lost draw is retried.
- A root systemd timer checks reachability every 5 minutes and re-activates
  Wi-Fi, toggles the radio, then reboots if the Pi stays offline for an hour.
- Optionally pings an Uptime Kuma push monitor after each successful run, so a
  stale screen raises an alert.
- Refuses to run if the Waveshare BUSY timeout patch is missing.
- Uses a lock, outer timeout, HTTP retries, display timeout, and BUSY-pin timeout
  so one bad refresh cannot pile up cron jobs indefinitely.

## Files

- `scripts/update_display.py` - WadsFrame fetch and display update.
- `scripts/update_display.sh` - cron-safe launcher with env loading, lock, timeout.
- `scripts/status.sh` - local diagnostic helper for stale screens and Wi-Fi issues.
- `scripts/network_watchdog.sh` - Wi-Fi recovery run by the watchdog timer.
- `config/systemd/trmnl-network-watchdog.{service,timer}` - root watchdog units.
- `trmnl-ws73.env.example` - local configuration template.
- `config/cron/user-crontab` - user crontab entries.
- `config/logrotate.d/trmnl-display` - log rotation for `cron.log`.
- `config/journald.conf.d/90-trmnl-persistent-storage.conf` - optional persistent journald config.
- `patches/waveshare-epd7in3e-busy-timeout.patch` - patch for Waveshare's unbounded BUSY wait.

## Install

Install the system packages:

```bash
sudo apt install python3-requests python3-pil python3-spidev python3-gpiozero logrotate
```

Install or clone Waveshare's e-Paper Python library so this path exists:

```bash
~/e-Paper/RaspberryPi_JetsonNano/python/lib/waveshare_epd/epd7in3e.py
```

Clone this repo on the Pi:

```bash
git clone https://github.com/runty/trmnl-ws73.git ~/trmnl-scripts
cd ~/trmnl-scripts
cp trmnl-ws73.env.example trmnl-ws73.env
chmod 600 trmnl-ws73.env
```

Edit `trmnl-ws73.env` if WadsFrame's address or the display id differ:

```bash
WADSFRAME_URL=http://192.168.22.102:3200/api/displays/ws73/eink.png
```

WadsFrame must list the display in `EINK_DISPLAYS` (`ws73:800x480`).

Install cron and log rotation:

```bash
crontab config/cron/user-crontab
sed \
  -e "s|/home/YOUR_USER|$HOME|g" \
  -e "s|su YOUR_USER YOUR_USER|su $(id -un) $(id -gn)|g" \
  config/logrotate.d/trmnl-display \
  | sudo tee /etc/logrotate.d/trmnl-display >/dev/null
sudo logrotate -d /etc/logrotate.d/trmnl-display
```

Optional but useful on Raspberry Pi OS:

```bash
sudo install -d -m 755 /etc/systemd/journald.conf.d
sudo install -m 644 config/journald.conf.d/90-trmnl-persistent-storage.conf /etc/systemd/journald.conf.d/
sudo systemctl restart systemd-journald
sudo journalctl --flush
```

Disable Wi-Fi power save for the active NetworkManager connection:

```bash
nmcli -g NAME connection show --active
sudo nmcli connection modify "<connection-name>" 802-11-wireless.powersave 2
```

That setting normally applies on the next reconnect or reboot.

Make NetworkManager retry the Wi-Fi connection forever instead of giving up
after four failed attempts:

```bash
sudo nmcli connection modify "<connection-name>" connection.autoconnect-retries 0
```

## Network Watchdog

The Pi Zero W's Wi-Fi can drop and never come back; in September 2026 ws73 sat
offline for six weeks showing a stale screen. Install the watchdog timer:

```bash
sed "s|/home/YOUR_USER|$HOME|g" config/systemd/trmnl-network-watchdog.service \
  | sudo tee /etc/systemd/system/trmnl-network-watchdog.service >/dev/null
sudo install -m 644 config/systemd/trmnl-network-watchdog.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now trmnl-network-watchdog.timer
```

Every 5 minutes it checks that WadsFrame's health URL on Shrimp
(`http://192.168.22.102:3200/api/health`, override with `TRMNL_WATCHDOG_URL`)
answers. If it does not and the default gateway also does not answer, it
re-activates `wlan0` after 2 failed checks, toggles the Wi-Fi radio from 4, and
reboots at 12 (one hour), at most once every 6 hours. When the gateway answers
but WadsFrame does not (Shrimp down or restarting), it only logs. Its messages
go to the journal under `trmnl-network-watchdog`.

Test the escalation without touching Wi-Fi by pointing it at a missing host and
an unreachable gateway in dry-run mode; each run adds one failure:

```bash
for i in $(seq 1 12); do
  sudo TRMNL_WATCHDOG_DRY_RUN=1 TRMNL_WATCHDOG_URL=http://nonexistent.invalid/ \
    TRMNL_WATCHDOG_GATEWAY=192.0.2.1 TRMNL_WATCHDOG_STATE=/tmp/wd-test \
    TRMNL_WATCHDOG_REBOOT_STAMP=/tmp/wd-test-reboot \
    ~/trmnl-scripts/scripts/network_watchdog.sh
done
sudo rm -f /tmp/wd-test /tmp/wd-test-reboot
```

## Stale-Screen Alert

Create an Uptime Kuma **Push** monitor (30 minute heartbeat interval, 1 retry,
so it alerts after about an hour without a successful draw) and put its push
URL in `trmnl-ws73.env`:

```bash
TRMNL_HEARTBEAT_URL=https://uptime.example.org/api/push/<token>
```

`update_display.sh` pings it after every successful run; a failed ping only
logs a warning. If the Kuma hostname resolves to an address the Pi cannot reach
(for example a Tailscale address), pin it to a LAN address with
`TRMNL_HEARTBEAT_RESOLVE=host:443:address`, which is passed to `curl --resolve`.

## Waveshare Busy Timeout

Waveshare's `epd7in3e.py` has an unbounded wait on the display BUSY pin. Apply
the patch so hardware/display stalls fail the update instead of leaving Python
blocked forever:

```bash
cd ~/e-Paper/RaspberryPi_JetsonNano/python/lib
patch -p1 < ~/trmnl-scripts/patches/waveshare-epd7in3e-busy-timeout.patch
```

The timeout defaults to 180 seconds and can be changed with:

```bash
WAVESHARE_BUSY_TIMEOUT=180
```

## Run Manually

```bash
~/trmnl-scripts/scripts/update_display.sh
tail -f ~/trmnl-scripts/cron.log
```

## Check a Stale Screen

Run the status helper on the Pi:

```bash
~/trmnl-scripts/scripts/status.sh
```

It checks:

- whether an updater or timeout process is still running
- the latest `cron.log` refresh attempt
- the last drawn slide's ETag
- whether WadsFrame's health URL answers
- NetworkManager and Wi-Fi events from the current boot
- temperature and throttling, when `vcgencmd` is available

If the log shows `NameResolutionError`, `link timed out`, or failed Wi-Fi
activation before the updater reaches `Initializing display...`, the screen is
stale because the Pi missed a network/WadsFrame refresh, not because the display path
hung. Once network is back, run:

```bash
~/trmnl-scripts/scripts/update_display.sh
```

If the updater stops after `Initializing display...` or `Pushing image to display...`,
check for the Waveshare BUSY timeout patch and inspect recent `brcmf`, SPI, and
GPIO messages in `journalctl`.

## Notes

Do not commit `trmnl-ws73.env`; it holds the Uptime Kuma push token.

To see what ws73 should be showing, open
`http://192.168.22.102:3200/api/displays/ws73/eink.png?preview=1` from the LAN:
the current slide as the panel shows it. Polling it does not move the slide on
before the hour.
