#!/usr/bin/env python3
import os
import signal
import sys
import time
from contextlib import contextmanager
from io import BytesIO

import requests
from PIL import Image


SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
WAVESHARE_LIB = os.path.expanduser(
    os.getenv("WAVESHARE_LIB", "~/e-Paper/RaspberryPi_JetsonNano/python/lib")
)
sys.path.insert(0, WAVESHARE_LIB)

from waveshare_epd import epd7in3e  # noqa: E402


BASE_URL = os.getenv("TRMNL_BASE_URL", "https://usetrmnl.com")
API_KEY = os.getenv("TRMNL_API_KEY", "")
MAC_ADDRESS = os.getenv("TRMNL_MAC", "")
TARGET_RES = (
    int(os.getenv("TRMNL_WIDTH", "800")),
    int(os.getenv("TRMNL_HEIGHT", "480")),
)
CACHE_FILE = os.path.expanduser(
    os.getenv("TRMNL_CACHE_FILE", os.path.join(SCRIPT_DIR, "last_image.txt"))
)
DISPLAY_MODEL = os.getenv("TRMNL_MODEL", "Waveshare 7.3 Spectra 6")
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


def validate_config():
    if not API_KEY:
        log("Missing TRMNL_API_KEY")
        return False
    if not MAC_ADDRESS:
        log("Missing TRMNL_MAC")
        return False
    return True


def update_display():
    if not validate_config():
        return False

    try:
        api_url = f"{BASE_URL}/api/display"
        headers = {
            "ID": MAC_ADDRESS,
            "Access-Token": API_KEY,
            "Content-Type": "application/json",
            "Width": str(TARGET_RES[0]),
            "Height": str(TARGET_RES[1]),
            "Model": DISPLAY_MODEL,
        }
        api_response = get_with_retries(api_url, headers=headers, timeout=30)
        try:
            if api_response.status_code != 200:
                log(f"API error: {api_response.status_code} {api_response.text[:200]}")
                return False
            data = api_response.json()
        finally:
            api_response.close()

        img_url = data.get("image_url")
        current_filename = data.get("filename") or data.get("image_name") or img_url

        if not img_url:
            log("No image URL in response")
            return False

        if os.path.exists(CACHE_FILE):
            with open(CACHE_FILE, "r", encoding="utf-8") as f:
                last_filename = f.read().strip()
            if current_filename == last_filename:
                log(f"No change detected ({current_filename}). Skipping update.")
                return True

        log(f"New image found: {current_filename}. Downloading...")

        if img_url.startswith("/"):
            img_url = f"{BASE_URL}{img_url}"

        img_response = get_with_retries(img_url, timeout=60)
        try:
            if img_response.status_code != 200:
                log(f"Image download failed: {img_response.status_code}")
                return False
            img = Image.open(BytesIO(img_response.content))
        finally:
            img_response.close()

        img = img.resize(TARGET_RES, Image.Resampling.LANCZOS).convert("RGB")

        epd = None
        cleanup_attempted = False
        try:
            with deadline(
                DISPLAY_TIMEOUT_SECONDS,
                f"display update exceeded {DISPLAY_TIMEOUT_SECONDS}s",
            ):
                log("Initializing display...")
                epd = epd7in3e.EPD()
                if epd.init() != 0:
                    raise RuntimeError("display init failed")
                log("Pushing image to display...")
                epd.display(epd.getbuffer(img))
            cleanup_attempted = True
            sleep_display(epd)
            epd = None
        finally:
            if epd is not None and not cleanup_attempted:
                try:
                    sleep_display(epd)
                except Exception as cleanup_error:
                    log(f"Display cleanup failed: {cleanup_error}")
                    raise

        with open(CACHE_FILE, "w", encoding="utf-8") as f:
            f.write(current_filename)

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
