# trmnl-ws73

TRMNL client for a Raspberry Pi OS host driving a Waveshare 7.3 inch Spectra 6
e-paper display.

This is the Linux/Python setup for a Raspberry Pi OS TRMNL frame. It is separate
from the Pico W / Pimoroni Inky Frame MicroPython client in `trmnlframe`.

## What It Does

- Fetches `/api/display` from TRMNL.
- Downloads the returned image only when the filename changes.
- Renders the image through Waveshare's `epd7in3e` Python driver.
- Runs from cron every 15 minutes and once after boot.
- Uses a lock, outer timeout, HTTP retries, display timeout, and BUSY-pin timeout
  so one bad refresh cannot pile up cron jobs indefinitely.

## Files

- `scripts/update_display.py` - TRMNL API fetch, image processing, display update.
- `scripts/update_display.sh` - cron-safe launcher with env loading, lock, timeout.
- `scripts/status.sh` - local diagnostic helper for stale screens and Wi-Fi issues.
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

Edit `trmnl-ws73.env` and set:

```bash
TRMNL_API_KEY=...
TRMNL_MAC=...
```

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
- the cached TRMNL image filename
- DNS and HTTPS reachability for `usetrmnl.com`
- NetworkManager and Wi-Fi events from the current boot
- temperature and throttling, when `vcgencmd` is available

If the log shows `NameResolutionError`, `link timed out`, or failed Wi-Fi
activation before the updater reaches `Initializing display...`, the screen is
stale because the Pi missed a network/API refresh, not because the display path
hung. Once network is back, run:

```bash
~/trmnl-scripts/scripts/update_display.sh
```

If the updater stops after `Initializing display...` or `Pushing image to display...`,
check for the Waveshare BUSY timeout patch and inspect recent `brcmf`, SPI, and
GPIO messages in `journalctl`.

## Notes

Do not commit `trmnl-ws73.env`; it contains the TRMNL API key and device MAC.
