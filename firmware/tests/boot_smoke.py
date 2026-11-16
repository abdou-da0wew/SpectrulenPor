#!/usr/bin/env python3
"""Capture a complete ESP32 boot on Linux with exclusive UART ownership."""

import argparse
import json
import re
import sys
import time
from pathlib import Path

FIRMWARE_ROOT = Path(__file__).resolve().parents[1]
if str(FIRMWARE_ROOT) not in sys.path:
    sys.path.insert(0, str(FIRMWARE_ROOT))

from testbench.errors import TestbenchError
from testbench.hardware_lock import HardwareLock
from testbench.settings import DEFAULT_ADAPTER
from standalone_signals import StandaloneSignals, StandaloneInterrupted


def capture_boot(port: str, baud: int, seconds: float, reset: bool,
                 interruption=None) -> bytes:
    try:
        import serial
    except ImportError as exc:
        raise RuntimeError("BOOT_PYSERIAL_MISSING") from exc

    # Set line levels before opening. RTS controls EN; DTR controls GPIO0.
    uart = serial.Serial(port=None, baudrate=baud, timeout=0.1)
    try:
        if interruption is not None:
            interruption.checkpoint()
        uart.port = port
        uart.dtr = False
        uart.rts = False
        uart.open()
        if interruption is not None:
            interruption.checkpoint()
        if reset:
            uart.rts = True
            time.sleep(0.1)
            uart.reset_input_buffer()
            uart.rts = False
        deadline = time.monotonic() + seconds
        output = bytearray()
        while time.monotonic() < deadline:
            if interruption is not None:
                interruption.checkpoint()
            output.extend(uart.read(max(1, uart.in_waiting)))
            if interruption is not None:
                interruption.checkpoint()
        return bytes(output)
    finally:
        if interruption is not None:
            interruption.begin_cleanup()
        failure = sys.exc_info()[1]
        cleanup_errors = []
        # A partial open or failed DTR reset must not skip RTS or close.
        for line in ("dtr", "rts"):
            try:
                setattr(uart, line, False)
            except BaseException as error:
                cleanup_errors.append(type(error).__name__)
        try:
            uart.close()
        except BaseException as error:
            cleanup_errors.append(type(error).__name__)
        if cleanup_errors:
            if failure is not None:
                failure.cleanup_errors = cleanup_errors
            else:
                failure = RuntimeError("BOOT_CLEANUP_INCOMPLETE")
                failure.cleanup_errors = cleanup_errors
                raise failure from None


def verify_boot(data: bytes, version: str, mode: str = "ble_setup") -> dict:
    text = data.decode("utf-8", errors="replace")
    ready = re.search(
        r"operation=boot.ready camera=(\d) sensor=(\d) psram=(\d+) version=(\S+)", text
    )
    failures = []
    if ready is None:
        failures.append("BOOT_NOT_READY")
    elif ready.group(4) != version:
        failures.append("BOOT_VERSION_MISMATCH")
    elif ready.group(1) != "1":
        failures.append("BOOT_CAMERA_NOT_READY")
    if f"operation=boot.mode mode={mode}" not in text:
        failures.append("BOOT_MODE_MISMATCH")
    if mode == "ble_setup":
        if "operation=ble.advertise" not in text:
            failures.append("BOOT_BLE_NOT_ADVERTISING")
        if "operation=wifi.start" in text:
            failures.append("BOOT_WIFI_STARTED_DURING_SETUP")
    elif "operation=ble.init" in text or "operation=ble.advertise" in text:
        failures.append("BOOT_BLE_STARTED_IN_WIFI_MODE")
    if "operation=camera.boot_capture" not in text or "jpeg=valid" not in text:
        failures.append("BOOT_CAMERA_CAPTURE_FAILED")
    if text.count("rst:") > 1:
        failures.append("BOOT_RESET_LOOP")
    if re.search(r"Guru Meditation|Brownout|abort\(\)|panic'ed|assert failed", text, re.I):
        failures.append("BOOT_RUNTIME_FAULT")
    return {
        "ok": not failures,
        "codes": failures,
        "captured_bytes": len(data),
        "reset_banners": text.count("rst:"),
        "camera": int(ready.group(1)) if ready else None,
        "sensor": int(ready.group(2)) if ready else None,
        "psram_bytes": int(ready.group(3)) if ready else None,
        "version": ready.group(4) if ready else None,
        "mode": mode,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--adapter", default=DEFAULT_ADAPTER)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--seconds", type=float, default=15)
    parser.add_argument("--version", required=True)
    parser.add_argument("--mode", choices=("ble_setup", "wifi_only"), default="ble_setup")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--reset", action="store_true")
    args = parser.parse_args()
    if args.seconds <= 0 or args.baud <= 0:
        parser.error("baud and capture duration must be positive")
    failure = None
    interruption = StandaloneSignals("BOOT_INTERRUPTED")
    try:
        with interruption:
            with interruption.owned(HardwareLock(args.adapter, args.port)):
                interruption.checkpoint()
                data = capture_boot(args.port, args.baud, args.seconds, args.reset, interruption)
    except BaseException as exc:
        failure = StandaloneInterrupted(interruption.code) if isinstance(exc, KeyboardInterrupt) else exc
    failure = interruption.final_failure(failure)
    try:
        if failure is not None:
            raise failure
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(data)
        result = verify_boot(data, args.version, args.mode)
        print(json.dumps(result, indent=2))
        return 0 if result["ok"] else 1
    except BaseException as exc:
        code = exc.code if isinstance(exc, (TestbenchError, StandaloneInterrupted)) else "BOOT_CAPTURE_FAILED"
        print(json.dumps({"ok": False, "code": code, "type": type(exc).__name__,
                          "cleanup_errors": getattr(exc, "cleanup_errors", []) + interruption.cleanup_errors,
                          "interrupted": interruption.signum is not None or isinstance(exc, StandaloneInterrupted)}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
