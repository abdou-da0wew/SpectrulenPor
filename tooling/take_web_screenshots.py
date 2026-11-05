#!/usr/bin/env python3
"""Capture in-app screenshots of SpectruLenPor running on Flutter Web in a
phone-sized (Pixel-7-like) headless browser, with a fake lab-scene camera."""

import subprocess
import sys
import time

from playwright.sync_api import sync_playwright

BASE = "http://localhost:8123"
OUT = "/home/z/my-project/SpectrulenPor/docs/screenshots"
Y4M = "/tmp/lab_scene.y4m"

ARGS = [
    "--use-fake-ui-for-media-stream",
    "--use-fake-device-for-media-stream",
    f"--use-file-for-fake-video-capture={Y4M}",
    "--autoplay-policy=no-user-gesture-required",
]


def wait_server() -> None:
    for _ in range(30):
        try:
            import urllib.request
            urllib.request.urlopen(BASE + "/", timeout=1)
            return
        except Exception:
            time.sleep(1)
    sys.exit("server did not come up")


def shoot(page, path: str, settle: int = 6500) -> None:
    page.wait_for_timeout(settle)
    page.screenshot(path=path)
    print("saved", path)


def main() -> None:
    wait_server()
    with sync_playwright() as p:
        browser = p.chromium.launch(args=ARGS)
        ctx = browser.new_context(
            viewport={"width": 412, "height": 915},
            device_scale_factor=2,
            is_mobile=True,
            has_touch=True,
            locale="en-US",
        )

        # --- English home: permission gate -> granted live preview ---
        page = ctx.new_page()
        page.goto(f"{BASE}/#/")
        shoot(page, f"{OUT}/01_home_gate.png", 8000)
        page.mouse.click(206, 566)  # "Grant Access" button center
        shoot(page, f"{OUT}/01_home_live.png", 5000)

        # --- Settings ---
        page.goto(f"{BASE}/#/settings")
        shoot(page, f"{OUT}/02_settings.png", 8000)
        page.mouse.wheel(0, 900)
        shoot(page, f"{OUT}/02b_settings_rag.png", 2500)

        # --- History & docs ---
        page.goto(f"{BASE}/#/history")
        shoot(page, f"{OUT}/03_history.png", 8000)

        # --- Diagnostics DB ---
        page.goto(f"{BASE}/#/diagnostics")
        shoot(page, f"{OUT}/04_diagnostics.png", 8000)

        page.close()

        # --- Arabic RTL home (live camera) ---
        ctx_ar = browser.new_context(
            viewport={"width": 412, "height": 915},
            device_scale_factor=2,
            is_mobile=True,
            has_touch=True,
            locale="ar-EG",
        )
        ctx_ar.add_init_script("window.localStorage.setItem('flutter.locale','ar');")
        page_ar = ctx_ar.new_page()
        page_ar.goto(f"{BASE}/#/")
        page_ar.wait_for_timeout(8000)
        page_ar.mouse.click(206, 566)
        shoot(page_ar, f"{OUT}/05_home_ar.png", 5000)

        browser.close()


if __name__ == "__main__":
    main()
