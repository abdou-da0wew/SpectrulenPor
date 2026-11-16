#!/usr/bin/env python3
"""Verify missing-AP retry exhaustion and NVS persistence on a setup fixture.

Leaves synthetic credentials on the board. An authorized NVS reset and real
provisioning must follow; this test never performs an automatic NVS erase.
"""

import argparse
import json
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

FIRMWARE_ROOT = Path(__file__).resolve().parents[1]
if str(FIRMWARE_ROOT) not in sys.path:
    sys.path.insert(0, str(FIRMWARE_ROOT))

from testbench.errors import TestbenchError
from testbench.hardware_lock import HardwareLock
from testbench.settings import DEFAULT_ADAPTER
from standalone_signals import StandaloneSignals, StandaloneInterrupted

from hardware_e2e import HardwareSuite, BLE_SCAN_SECONDS, REPLY_TIMEOUT, TEST_PASSWORD
from hardware_helpers import BluezClient, UARTLog, require, UART_WAIT_SECONDS


def retry_settings() -> tuple[int, float]:
    """Use the retry limits compiled from this checkout's config.h."""
    config = (Path(__file__).resolve().parents[1] / "config.h").read_text()
    values = {}
    for name in ("WIFI_MAX_RETRIES", "WIFI_CONNECT_TIMEOUT_MS", "WIFI_RETRY_INTERVAL_MS"):
        match = re.search(r"^#define\s+" + name + r"\s+(\d+)\s*$", config, re.M)
        require(match is not None, "HIL_RETRY_CONFIG_MISSING")
        values[name] = int(match.group(1))
        require(values[name] > 0, "HIL_RETRY_CONFIG_INVALID")
    per_attempt = (values["WIFI_CONNECT_TIMEOUT_MS"] + values["WIFI_RETRY_INTERVAL_MS"]) / 1000
    return values["WIFI_MAX_RETRIES"], per_attempt


def missing_ap_evidence(uart, client, since: int, attempts: int,
                        per_attempt: float, exhausted: bool) -> dict:
    uart.wait(r"rst:.*RESET", since, code="HIL_REBOOT_NOT_OBSERVED")
    uart.wait(r"operation=boot.mode mode=wifi_only ble=0", since,
              code="HIL_WIFI_ONLY_BOOT_MISSING")
    uart.wait(r"operation=boot.ready camera=1", since, code="HIL_CAMERA_BOOT_FAILED")
    uart.wait(r"operation=wifi.connect_attempt attempt=" + str(attempts) + r" outcome=started",
              since, attempts * per_attempt + UART_WAIT_SECONDS, "HIL_WIFI_RETRY_NOT_OBSERVED")
    uart.wait_count(r"operation=wifi.disconnect reason=201\b", attempts,
                    since, per_attempt + UART_WAIT_SECONDS, "HIL_NO_AP_FAILURE_NOT_OBSERVED")
    if exhausted:
        uart.wait(r"\$STATUS:bt=0,wifi=failed,[^\r\n]*\r?\n", since,
                  UART_WAIT_SECONDS, "HIL_RETRY_EXHAUSTION_NOT_OBSERVED")
        # Observe beyond one retry window so an extra attempt cannot hide.
        client.pump(per_attempt)
    client.assert_not_advertising(BLE_SCAN_SECONDS)
    text = uart.text(since)
    require(len(re.findall(r"rst:.*RESET", text)) == 1, "HIL_UNEXPECTED_RESET")
    observed = [int(value) for value in re.findall(r"operation=wifi.connect_attempt attempt=(\d+)", text)]
    require(observed == list(range(1, attempts + 1)), "HIL_RETRY_SEQUENCE_MISMATCH")
    failures = len(re.findall(r"operation=wifi.disconnect reason=201\b", text))
    require(failures == attempts, "HIL_NO_AP_FAILURE_COUNT_MISMATCH")
    require("operation=wifi.got_ip" not in text, "HIL_MISSING_AP_WAS_REACHABLE")
    require("operation=ble.init" not in text and "operation=ble.advertise" not in text,
            "HIL_BLE_STARTED_IN_WIFI_MODE")
    require(re.search(r"Guru Meditation|Brownout|abort\(\)|panic'ed|assert failed", text, re.I) is None,
            "HIL_UART_RUNTIME_FAULT")
    return {"attempts": observed, "no_ap_failures": failures,
            "retry_exhausted": exhausted, "ble_initialized": False,
            "post_exhaustion_observation_seconds": per_attempt if exhausted else 0,
            "fresh_ble_scan_seconds": BLE_SCAN_SECONDS}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--adapter", default=DEFAULT_ADAPTER)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"timestamp": datetime.now(timezone.utc).isoformat(), "ok": False,
              "requires_authorized_nvs_reset_after_test": True, "cases": []}
    suite = None
    client = None
    uart = None
    failure = None
    interruption = StandaloneSignals()
    try:
        with interruption:
            with interruption.owned(HardwareLock(args.adapter, args.port)):
                try:
                    interruption.checkpoint()
                    retries, per_attempt = retry_settings()
                    interruption.checkpoint()
                    client = BluezClient(args.adapter)
                    interruption.checkpoint()
                    interruption.bind_client(client)
                    suite = HardwareSuite(client, args.output, None)
                    suite.interruption = interruption
                    interruption.checkpoint()
                    uart = UARTLog(args.port, args.output / "uart.log")
                    interruption.checkpoint()
                    with interruption.owned(uart):
                        suite.uart = uart
                        interruption.bind_uart(uart)
                        try:
                            interruption.checkpoint()
                            mark = uart.reset()
                            uart.wait(r"operation=boot.mode mode=ble_setup ble=1", mark,
                                      code="HIL_SETUP_REQUIRES_CLEAN_NVS")
                            suite.case("advertisement_and_gatt", suite.advertisement_and_gatt)

                            def provision_missing_ap():
                                client.pair()
                                missing_ssid = "SLP-HIL-" + uuid.uuid4().hex[:12]
                                suite.provision(missing_ssid, TEST_PASSWORD)
                                require(suite.wifi_config_get() == missing_ssid, "HIL_WIFI_CONFIG_MISMATCH")
                                require(suite.status()["wifi"] == "disconnected", "HIL_WIFI_STARTED_DURING_SETUP")
                                return {"configuration_readback": True, "wifi_started_during_setup": False}

                            suite.case("missing_ap_provisioning", provision_missing_ap)
                            mark = uart.mark()
                            interruption.checkpoint()
                            client.reboot()
                            client.wait(lambda: not client.manager.GetManagedObjects().get(
                                client.device_path, {}).get("org.bluez.Device1", {}).get("Connected", False),
                                REPLY_TIMEOUT, "HIL_REBOOT_DID_NOT_DISCONNECT_BLE")
                            client.disconnect()
                            suite.phase = "wifi"
                            suite.case("missing_ap_retry_exhaustion", lambda: missing_ap_evidence(
                                uart, client, mark, retries, per_attempt, True))
                            mark = uart.reset()
                            suite.case("missing_ap_nvs_persistence", lambda: missing_ap_evidence(
                                uart, client, mark, min(2, retries), per_attempt, False))
                            require(uart.error is None, "HIL_UART_CAPTURE_ERROR")
                        finally:
                            suite.cleanup(disconnect=False)
                finally:
                    interruption.begin_cleanup()
                    failed = sys.exc_info()[0] is not None
                    if client is not None:
                        try:
                            client.disconnect()
                        except BaseException as exc:
                            report["cleanup_error_type"] = type(exc).__name__
                            if not failed:
                                raise RuntimeError("HIL_CLEANUP_INCOMPLETE") from None
    except BaseException as exc:
        failure = StandaloneInterrupted(interruption.code) if isinstance(exc, KeyboardInterrupt) else exc
    failure = interruption.final_failure(failure)
    report["ok"] = failure is None
    if failure is not None:
        report["error_type"] = type(failure).__name__
        report["code"] = (failure.code if isinstance(failure, TestbenchError) else
                          str(failure) if isinstance(failure, (AssertionError, RuntimeError, TimeoutError)) else "HIL_TEST_FAILED")
    report["cases"] = suite.records if suite else []
    report["uart_cleanup_errors"] = list(getattr(uart, "cleanup_errors", ()))
    report["cleanup_errors"] = (suite.cleanup_errors if suite else []) + interruption.cleanup_errors
    report["configuration_may_require_recovery"] = bool(suite and suite.wifi_dirty)
    report["interrupted"] = interruption.signum is not None or isinstance(failure, StandaloneInterrupted)
    (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2), flush=True)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
