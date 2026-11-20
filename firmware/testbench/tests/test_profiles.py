"""Aggregate verification requires a complete, current UART-backed contract."""

import contextlib
import copy
import re
import threading
import unittest
from collections import deque
from types import SimpleNamespace
from unittest.mock import patch

from testbench.errors import safe_error
from testbench.hil import suites
from testbench.profiles import BLE_CAPTURE_CASE, CONTRACT_CASES
from testbench.tests.fakes import FAKE_JPEG, FakeLock, fake_engine
from testbench.transport import WIRE


FIXTURE_WIFI = {"ssid": "fixture-network", "password": "fixture-password"}
FIXTURE_IP = "192.0.2.10"
IMAGE_BLE = {"bytes": len(FAKE_JPEG), "width": 320, "height": 240}
IMAGE_UDP = {"bytes": len(FAKE_JPEG), "width": 800, "height": 600}
CONTRACT_DETAILS = {
    "advertisement_and_gatt": {"gatt_contract": True},
    "ble_stream_and_pause": {"decoded_frames": 3},
    "wifi_provisioning": {
        "software_reboot_observed": True, "wifi": "connected", "ble_initialized": False,
        "ble_scan_seconds": 5, "esp_mac": "AA:BB:CC:DD:EE:FF",
        "esp_hostname": "spectrulenpor-fixture", "ip": FIXTURE_IP,
    },
    "udp_single_frame": dict(IMAGE_UDP),
    "udp_stream_and_pause": {"decoded_frames": 30},
    "udp_controls_and_peer_handover": {
        "flash_on_off": True, "invalid_and_other_peer_commands_not_executed": True,
        "unicast_handover": True, "original_peer_reclaimed": True,
    },
    "restart_and_nvs_recovery": {
        "hardware_reset_observed": True, "wifi_credentials_persisted": True,
        "wifi_connected": True, "ble_initialized": False, "udp_image": dict(IMAGE_UDP),
    },
    "final_integrity": {"runtime_faults": 0, "frame_errors": 0, "notification_errors": 0},
    "paused_single_frame": dict(IMAGE_BLE),
    "ble_single_frame": dict(IMAGE_BLE),
    "flashlight_and_real_images": {"gpio_on_off": True},
}


class FixtureClock:
    def __init__(self):
        self.now = 0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class FixtureUART:
    """Satisfy setup waits without opening serial or asserting physical evidence."""

    def __init__(self, port, cooperate):
        self.error = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return

    def poll(self):
        return

    def mark(self):
        return 0

    def reset(self):
        return 0

    def wait(self, pattern, *args, **kwargs):
        text = "operation=boot.mode mode=ble_setup ble=1\noperation=ble.advertise\n"
        match = re.search(pattern, text)
        if match is None:
            raise TimeoutError(kwargs.get("code", "HIL_UART_REPLY_TIMEOUT"))
        return match

    def text(self, since=0):
        return "fixture clean runtime log"


class FixtureUDP:
    def __init__(self, ip, *, cooperate, on_frame):
        self.peer = (ip, WIRE.UDP_PORT)
        self.cooperate, self.on_frame = cooperate, on_frame
        self.ready = deque()
        self.closed = self.streaming = False
        self.datagrams = self.packets = self.dropped_frames = 0
        self.assembly = SimpleNamespace(
            protocol_errors=0, parts={}, total=0, packets=0, parity_packets=0
        )

    def command(self, command):
        self.cooperate()
        if command == bytes([WIRE.CMD_STREAM_ON]):
            self.streaming = True
        elif command == bytes([WIRE.CMD_STREAM_OFF]):
            self.streaming = False

    def request_control(
        self, command, prefix, timeout=4, attempts=3, echo=None,
        required_status_copies=2,
    ):
        self.command(command)
        if prefix == "$STATUS:":
            return "$STATUS:bt=0,wifi=connected,stream=0"
        return prefix

    def next_frame(self, **kwargs):
        import time
        self.cooperate()
        stamp = time.monotonic()
        self.datagrams += 1
        self.packets += 1
        self.assembly.packets += 1
        self.on_frame(stamp, FAKE_JPEG, "udp")
        return stamp, FAKE_JPEG

    def poll(self):
        if self.streaming:
            self.next_frame()

    def drain(self):
        self.ready.clear()

    def close(self):
        self.closed = True


class ProfileVerificationTests(unittest.TestCase):
    def tearDown(self):
        self.assertFalse(FakeLock.held)

    def run_profile(self, profile, *, uart=True, details=None, omit=(), fail=None, cleanup_failure=False,
                    prior_verified=False, ip=False):
        main, retry = suites()
        evidence = copy.deepcopy(CONTRACT_DETAILS if details is None else details)
        clock = FixtureClock()
        engine = fake_engine(uart="fixture-uart" if uart else None, uart_factory=FixtureUART,
                             udp_factory=FixtureUDP)
        engine.owner = threading.get_ident()
        engine.verifications.update(firmware=prior_verified, mobile_contract=prior_verified)
        engine.state["job"] = {"id": "fixture-job", "profile": profile, "status": "running", "records": []}
        params = {"profile": profile, "confirm_configuration": True, **FIXTURE_WIFI}
        if not uart or ip:
            params["ip"] = FIXTURE_IP
        if profile == "soak":
            params["duration"] = 1

        def status(suite):
            return {"wifi": "disconnected", "sensor": "0", "errors": "0",
                    "notify_errors": "0", "heap": "100000", "min_heap": "90000"}

        def wifi_connect(suite):
            suite.phase = "wifi"
            return copy.deepcopy(evidence["wifi_provisioning"])

        def provision(suite, ssid, password):
            suite.fixture_ssid = ssid

        def replay(suite):
            names = ("advertisement_and_gatt", "paused_single_frame", "ble_stream_and_pause",
                     "flashlight_and_real_images") + CONTRACT_CASES[2:]
            for name in names:
                if name in omit:
                    continue

                def observed(name=name):
                    if name == fail:
                        raise TimeoutError("HIL_FIXTURE_EVIDENCE_FAILED")
                    return copy.deepcopy(evidence[name])

                suite.case(name, observed)
            if cleanup_failure:
                raise RuntimeError("HIL_CLEANUP_INCOMPLETE")

        with contextlib.ExitStack() as stack:
            stack.enter_context(patch("testbench.engine.time.monotonic", side_effect=clock.monotonic))
            stack.enter_context(patch("testbench.engine.time.sleep", side_effect=clock.sleep))
            stack.enter_context(patch.object(engine, "_quiet"))
            stack.enter_context(patch.object(main.HardwareSuite, "run", replay))
            stack.enter_context(patch.object(main.HardwareSuite, "status", status))
            stack.enter_context(patch.object(main.HardwareSuite, "provision", provision))
            stack.enter_context(patch.object(main.HardwareSuite, "wifi_config_get",
                                             lambda suite: getattr(suite, "fixture_ssid", "")))
            stack.enter_context(patch.object(main.HardwareSuite, "wifi_connect", wifi_connect))
            methods = {
                "advertisement_and_gatt": "advertisement_and_gatt", "single_frame": "ble_single_frame",
                "ble_stream": "ble_stream_and_pause", "udp_single": "udp_single_frame",
                "udp_stream": "udp_stream_and_pause", "udp_controls_and_peer": "udp_controls_and_peer_handover",
                "restart": "restart_and_nvs_recovery",
            }
            for method, name in methods.items():
                def observed(suite, name=name):
                    if name == fail:
                        raise TimeoutError("HIL_FIXTURE_EVIDENCE_FAILED")
                    return copy.deepcopy(evidence[name])
                stack.enter_context(patch.object(main.HardwareSuite, method, observed))
            stack.enter_context(patch.object(retry, "retry_settings", return_value=(2, 1)))
            stack.enter_context(patch.object(retry, "missing_ap_evidence", return_value={
                "attempts": [1, 2], "no_ap_failures": 2, "ble_initialized": False,
            }))
            try:
                # Populate only fake notification counters needed by the real integrity method.
                original_factory = engine.client_factory

                def client_factory(*args):
                    client = original_factory(*args)
                    client.max_notification_bytes = client.notifications = 0
                    return client

                engine.client_factory = client_factory
                engine._execute("test", params)
                engine.state["job"]["status"] = "passed"
            except Exception as error:
                failure = safe_error(error)
                engine.state["job"]["status"] = "failed"
                engine.state["job"]["error"] = failure.public()
            finally:
                engine._cleanup()
        engine.close()
        return engine.report()

    def assert_aggregate(self, report, verified):
        self.assertIs(report["verifications"]["firmware"], verified)
        self.assertIs(report["verifications"]["mobile_contract"], verified)
        self.assertEqual(report["verifications"]["android"], "pending")
        self.assertEqual(report["verifications"]["sensor"], "pending")
        self.assertFalse(report["android_verified"])
        self.assertFalse(report["sensor_verified"])
        self.assertEqual(report["mobile_contract_platform"], "linux")

    def test_no_uart_mobile_flow_preserves_passes_but_not_aggregate_verification(self):
        report = self.run_profile("mobile-flow", uart=False)
        self.assertTrue(report["ok"], report["job"])
        self.assert_aggregate(report, False)
        self.assertTrue(all(record["ok"] for record in report["cases"]))
        cases = {record["name"]: record["details"] for record in report["cases"]}
        for name in ("ble_capture_contract", "ble_pair_and_provision", "reboot_disconnect", "decoded_udp_attach"):
            self.assertIn(name, cases)
        self.assertTrue(cases["decoded_udp_attach"]["decoded_jpeg"])
        self.assertFalse(cases["reboot_disconnect"]["boot_observed"])
        self.assertFalse(cases["reboot_disconnect"]["nvs_persistence_verified"])
        self.assertFalse(cases["flash_controls_and_images"]["gpio_state_verified"])
        self.assertIn(("nvs_persistence", "pending", "TB_UART_REQUIRED"),
                      [(event["operation"], event["outcome"], event.get("code")) for event in report["events"]])

    def test_smoke_alone_never_promotes_with_or_without_uart(self):
        for uart in (False, True):
            with self.subTest(uart=uart):
                report = self.run_profile("smoke", uart=uart)
                self.assertTrue(report["ok"], report["job"])
                self.assert_aggregate(report, False)
                self.assertEqual(len(report["cases"]), 3)
                self.assertTrue(all(record["ok"] for record in report["cases"]))

    def test_udp_smoke_without_uart_retains_unverified_gpio_and_decoded_images(self):
        report = self.run_profile("smoke", uart=False, ip=True)
        self.assertTrue(report["ok"], report["job"])
        self.assert_aggregate(report, False)
        flash = next(record["details"] for record in report["cases"] if record["name"] == "flash_controls_and_images")
        self.assertFalse(flash["gpio_state_verified"])
        self.assertEqual(flash["decoded_images"], 2)

    def test_soak_alone_never_promotes_with_or_without_uart(self):
        for uart in (False, True):
            with self.subTest(uart=uart):
                report = self.run_profile("soak", uart=uart)
                self.assertTrue(report["ok"], report["job"])
                self.assert_aggregate(report, False)
                self.assertEqual(report["cases"][0]["name"], "decoded_frame_soak")
                self.assertGreater(report["cases"][0]["details"]["decoded_frames"], 0)

    def test_missing_ap_remains_partial_and_keeps_recovery_required(self):
        report = self.run_profile("missing-ap")
        self.assertTrue(report["ok"], report["job"])
        self.assert_aggregate(report, False)
        self.assertTrue(report["configuration_may_require_recovery"])
        cases = {record["name"]: record for record in report["cases"]}
        for name in ("missing_ap_retry_exhaustion", "missing_ap_nvs_persistence"):
            self.assertTrue(cases[name]["ok"])
            self.assertEqual(cases[name]["details"]["attempts"], [1, 2])

    def test_complete_uart_full_contract_promotes_aggregate(self):
        report = self.run_profile("full")
        self.assertTrue(report["ok"], report["job"])
        self.assert_aggregate(report, True)

    def test_complete_uart_mobile_contract_promotes_aggregate(self):
        report = self.run_profile("mobile-flow")
        self.assertTrue(report["ok"], report["job"])
        self.assert_aggregate(report, True)

    def test_uart_required_profiles_cannot_promote_without_uart(self):
        for profile in ("full", "missing-ap"):
            with self.subTest(profile=profile):
                report = self.run_profile(profile, uart=False, prior_verified=True)
                self.assertFalse(report["ok"])
                self.assert_aggregate(report, False)
                self.assertEqual(report["job"]["error"]["code"], "TB_UART_REQUIRED")
                self.assertEqual(report["cases"], [])

    def test_missing_required_case_never_promotes_using_remaining_passes(self):
        required = CONTRACT_CASES + (BLE_CAPTURE_CASE["full"], "flashlight_and_real_images")
        for missing in required:
            with self.subTest(missing=missing):
                report = self.run_profile("full", omit=(missing,))
                self.assert_aggregate(report, False)
                self.assertTrue(report["cases"])
                self.assertTrue(all(record["ok"] for record in report["cases"]))
                self.assertNotIn(missing, [record["name"] for record in report["cases"]])

    def test_missing_or_false_required_details_never_promote(self):
        required = {
            "wifi_provisioning": ("software_reboot_observed", "wifi", "ble_initialized", "ble_scan_seconds"),
            "restart_and_nvs_recovery": ("hardware_reset_observed", "wifi_credentials_persisted",
                                         "wifi_connected", "ble_initialized", "udp_image"),
            "paused_single_frame": ("bytes", "width", "height"),
            "udp_single_frame": ("bytes", "width", "height"),
            "ble_stream_and_pause": ("decoded_frames",),
            "udp_stream_and_pause": ("decoded_frames",),
            "udp_controls_and_peer_handover": tuple(CONTRACT_DETAILS["udp_controls_and_peer_handover"]),
            "final_integrity": ("runtime_faults", "frame_errors", "notification_errors"),
            "flashlight_and_real_images": ("gpio_on_off",),
        }
        for case, fields in required.items():
            for field in fields:
                for invalid in (None, "unverified"):
                    with self.subTest(case=case, field=field, invalid=invalid):
                        details = copy.deepcopy(CONTRACT_DETAILS)
                        if invalid is None:
                            details[case].pop(field)
                        else:
                            details[case][field] = invalid
                        report = self.run_profile("full", details=details)
                        self.assertTrue(report["ok"], report["job"])
                        self.assert_aggregate(report, False)
                        self.assertTrue(all(record["ok"] for record in report["cases"]))

    def test_adaptive_udp_resolutions_promote_with_real_image_evidence(self):
        main, _ = suites()
        for width, height in sorted(main.UDP_FRAME_SIZES):
            with self.subTest(width=width, height=height):
                details = copy.deepcopy(CONTRACT_DETAILS)
                for case in ("udp_single_frame", "restart_and_nvs_recovery"):
                    image_key = "udp_image" if case == "restart_and_nvs_recovery" else None
                    image = details[case][image_key] if image_key else details[case]
                    image["width"], image["height"] = width, height
                report = self.run_profile("mobile-flow", details=details)
                self.assertTrue(report["ok"], report["job"])
                self.assert_aggregate(report, True)

    def test_false_nvs_wrong_image_and_unverified_controls_do_not_promote(self):
        for case, field, invalid in (
            ("restart_and_nvs_recovery", "wifi_credentials_persisted", False),
            ("restart_and_nvs_recovery", "udp_image", {
                "bytes": len(FAKE_JPEG), "width": 160, "height": 120,
            }),
            ("udp_controls_and_peer_handover", "flash_on_off", False),
            ("ble_stream_and_pause", "decoded_frames", 0),
            ("ble_stream_and_pause", "decoded_frames", True),
            ("udp_single_frame", "bytes", True),
        ):
            with self.subTest(case=case, field=field):
                details = copy.deepcopy(CONTRACT_DETAILS)
                details[case][field] = invalid
                report = self.run_profile("mobile-flow", details=details)
                self.assertTrue(report["ok"], report["job"])
                self.assert_aggregate(report, False)

    def test_failed_evidence_keeps_partial_passes_and_aggregate_false(self):
        for profile in ("full", "mobile-flow"):
            with self.subTest(profile=profile):
                report = self.run_profile(profile, fail="restart_and_nvs_recovery")
                self.assertFalse(report["ok"])
                self.assert_aggregate(report, False)
                self.assertTrue(any(record["ok"] for record in report["cases"]))
                self.assertEqual(report["cases"][-1]["code"], "HIL_FIXTURE_EVIDENCE_FAILED")

    def test_full_cleanup_failure_after_all_passes_does_not_promote(self):
        report = self.run_profile("full", cleanup_failure=True)
        self.assertFalse(report["ok"])
        self.assert_aggregate(report, False)
        self.assertTrue(all(record["ok"] for record in report["cases"]))
        self.assertEqual(report["job"]["error"]["code"], "HIL_CLEANUP_INCOMPLETE")

    def test_nvs_boolean_survives_public_redaction_without_credentials(self):
        report = self.run_profile("mobile-flow")
        recovery = next(record["details"] for record in report["cases"] if record["name"] == "restart_and_nvs_recovery")
        self.assertTrue(recovery["nvs_persistence_verified"])
        self.assertNotIn("wifi_credentials_persisted", recovery)
        self.assertNotIn(FIXTURE_WIFI["ssid"], str(report))
        self.assertNotIn(FIXTURE_WIFI["password"], str(report))

    def test_partial_new_profile_clears_stale_aggregate_flags(self):
        for profile, uart in (("smoke", True), ("soak", True), ("missing-ap", True), ("mobile-flow", False)):
            with self.subTest(profile=profile, uart=uart):
                report = self.run_profile(profile, uart=uart, prior_verified=True)
                self.assertTrue(report["ok"], report["job"])
                self.assert_aggregate(report, False)


if __name__ == "__main__":
    unittest.main()
