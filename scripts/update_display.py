#!/usr/bin/env python3
# Draws ws73's WadsFrame slide on the Waveshare 7.3" Spectra 6 panel when it changes.
# WadsFrame (on Shrimp) picks the slide and dithers it to the panel's six inks; this script only
# fetches the PNG, skipping the draw while the slide's ETag is unchanged.
import os
import signal
import sys
import time
from contextlib import contextmanager
from io import BytesIO

import requests
from PIL import Image


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.dirname(SCRIPT_DIR)
WAVESHARE_LIB = os.path.expanduser(
    os.getenv("WAVESHARE_LIB", "~/e-Paper/RaspberryPi_JetsonNano/python/lib")
)
sys.path.insert(0, WAVESHARE_LIB)

from waveshare_epd import epd7in3e  # noqa: E402

# The stock driver waits on BUSY forever; patches/ adds a bounded wait.
BUSY_PATCH_APPLIED = hasattr(epd7in3e, "BUSY_TIMEOUT_SECONDS")


IMAGE_URL = os.getenv(
    "WADSFRAME_URL", "http://192.168.22.102:3200/api/displays/ws73/eink.png"
)
TARGET_RES = (
    int(os.getenv("TRMNL_WIDTH", "800")),
    int(os.getenv("TRMNL_HEIGHT", "480")),
)
CACHE_FILE = os.path.expanduser(
    os.getenv("TRMNL_CACHE_FILE", os.path.join(PROJECT_DIR, "last_image.txt"))
)
# A real Spectra 6 refresh holds BUSY for ~30s; a much faster "success" means
# the panel did not actually redraw.
MIN_REFRESH_SECONDS = float(os.getenv("TRMNL_MIN_REFRESH_SECONDS", "10"))
# Redraw an unchanged image after this long, in case an earlier draw was lost.
FORCE_REDRAW_HOURS = float(os.getenv("TRMNL_FORCE_REDRAW_HOURS", "12"))
DISPLAY_TIMEOUT_SECONDS = int(os.getenv("TRMNL_DISPLAY_TIMEOUT", "600"))
DISPLAY_CLEANUP_TIMEOUT_SECONDS = int(os.getenv("TRMNL_DISPLAY_CLEANUP_TIMEOUT", "30"))
HTTP_ATTEMPTS = int(os.getenv("TRMNL_HTTP_ATTEMPTS", "3"))
HTTP_RETRY_DELAY_SECONDS = int(os.getenv("TRMNL_HTTP_RETRY_DELAY", "5"))
HTTP_TOTAL_TIMEOUT_SECONDS = int(os.getenv("TRMNL_HTTP_TOTAL_TIMEOUT", "120"))


def log(message):
    print(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} {message}", flush=True)


@contextmanager
def deadline(seconds, message):
    def _raise_timeout(signum, frame):
        raise TimeoutError(message)

    old_handler = signal.getsignal(signal.SIGALRM)
    signal.signal(signal.SIGALRM, _raise_timeout)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, old_handler)


def get_with_retries(url, total_timeout=HTTP_TOTAL_TIMEOUT_SECONDS, **kwargs):
    with deadline(total_timeout, f"HTTP request sequence exceeded {total_timeout}s"):
        for attempt in range(1, HTTP_ATTEMPTS + 1):
            try:
                return requests.get(url, **kwargs)
            except requests.RequestException as e:
                if attempt == HTTP_ATTEMPTS:
                    raise
                log(f"HTTP request failed on attempt {attempt}/{HTTP_ATTEMPTS}: {e}; retrying")
                time.sleep(HTTP_RETRY_DELAY_SECONDS * attempt)
    raise TimeoutError(f"HTTP request sequence exceeded {total_timeout}s")


def _raise_termination(signum, frame):
    raise SystemExit(128 + signum)


def sleep_display(epd):
    with deadline(
        DISPLAY_CLEANUP_TIMEOUT_SECONDS,
        f"display sleep/cleanup exceeded {DISPLAY_CLEANUP_TIMEOUT_SECONDS}s",
    ):
        log("Sleeping display...")
        epd.sleep()


def read_cache():
    """The last drawn slide's ETag and the cache's age in hours, or ("", None)."""
    if not os.path.exists(CACHE_FILE):
        return "", None
    with open(CACHE_FILE, "r", encoding="utf-8") as f:
        etag = f.read().strip()
    return etag, (time.time() - os.path.getmtime(CACHE_FILE)) / 3600


def write_cache(etag):
    tmp = f"{CACHE_FILE}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(etag)
    os.replace(tmp, CACHE_FILE)


def validate_config():
    if not BUSY_PATCH_APPLIED:
        log(
            "Waveshare BUSY timeout patch is missing from "
            f"{epd7in3e.__file__}; reapply patches/waveshare-epd7in3e-busy-timeout.patch"
        )
        return False
    return True


def update_display():
    if not validate_config():
        return False

    try:
        last_etag, cache_age_hours = read_cache()
        headers = {}
        # Past FORCE_REDRAW_HOURS, fetch without If-None-Match so an unchanged slide is redrawn
        # too, in case an earlier draw was lost.
        if last_etag and (FORCE_REDRAW_HOURS <= 0 or cache_age_hours < FORCE_REDRAW_HOURS):
            headers["If-None-Match"] = last_etag
        response = get_with_retries(IMAGE_URL, headers=headers, timeout=60)
        try:
            if response.status_code == 304:
                log(f"No change detected ({last_etag}). Skipping update.")
                return True
            if response.status_code != 200:
                log(f"WadsFrame error: {response.status_code} {response.text[:200]}")
                return False
            etag = response.headers.get("ETag", "")
            img = Image.open(BytesIO(response.content))
            img.load()
        finally:
            response.close()

        if etag and etag == last_etag:
            log(f"Slide unchanged for {cache_age_hours:.1f}h ({etag}); redrawing anyway.")
        else:
            log(f"New slide: {etag or 'no ETag'}.")

        # WadsFrame sends the panel's own colours, already dithered; resizing would spoil that.
        img = img.convert("RGB")
        if img.size != TARGET_RES:
            log(f"Slide is {img.size[0]}x{img.size[1]}, expected {TARGET_RES[0]}x{TARGET_RES[1]}")
            return False

        epd = None
        try:
            with deadline(
                DISPLAY_TIMEOUT_SECONDS,
                f"display update exceeded {DISPLAY_TIMEOUT_SECONDS}s",
            ):
                log("Initializing display...")
                epd = epd7in3e.EPD()
                if epd.init() != 0:
                    raise RuntimeError("display init failed")
                buffer = epd.getbuffer(img)
                log("Pushing image to display...")
                refresh_start = time.monotonic()
                epd.display(buffer)
                refresh_seconds = time.monotonic() - refresh_start
                log(f"Panel refresh took {refresh_seconds:.1f}s")
                if refresh_seconds < MIN_REFRESH_SECONDS:
                    raise RuntimeError(
                        f"panel refresh took only {refresh_seconds:.1f}s; "
                        "display did not redraw"
                    )
        except BaseException as draw_error:
            # Log the draw failure before cleanup, so a cleanup failure on a
            # wedged panel cannot hide the original cause.
            log(f"Display update failed: {draw_error!r}")
            if epd is not None:
                try:
                    sleep_display(epd)
                except Exception as cleanup_error:
                    log(f"Display cleanup also failed: {cleanup_error}")
            raise
        sleep_display(epd)

        write_cache(etag)

        log("Update complete!")
        return True

    except TimeoutError as e:
        log(f"Timeout: {e}")
        return False
    except Exception as e:
        log(f"Error: {e}")
        return False


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, _raise_termination)
    signal.signal(signal.SIGINT, _raise_termination)
    sys.exit(0 if update_display() else 1)
