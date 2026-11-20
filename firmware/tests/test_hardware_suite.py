"""Regression checks for HIL reporting and transport phase boundaries."""

import re
import unittest
from collections import deque
from pathlib import Path
from unittest.mock import Mock, patch

from boot_smoke import verify_boot
from hardware_e2e import HardwareSuite, WIFI_TIMEOUT
from hardware_helpers import UARTLog, UdpFrames
from wifi_retry_hil import missing_ap_evidence, retry_settings


STATUS = ("$STATUS:bt=0,wifi=connected,ip=192.168.1.2,flash=0,stream=0,camera=1,"
          "sensor=0,psram=8388608,frames=1,errors=0,notify_errors=0,heap=100000,min_heap=90000\n")
VERSION = "3.2.0"


class FakeDBusError(Exception):
    def __init__(self, name, message):
        self.name, self.message = name, message

    def get_dbus_name(self):
        return self.name

    def get_dbus_message(self):
        return self.message


class HardwareSuiteTests(unittest.TestCase):
    def setUp(self):
        self.client = Mock(rx=None)
        self.suite = HardwareSuite(self.client, Path("unused-test-output"), ("TestAP", "TestPass123"))
        self.suite.uart = Mock()
        self.client.dbus.DBusException = FakeDBusError

    def test_initial_commissioning_accepts_empty_nvs_ble_boot(self):
        boot = re.search(
            r"operation=boot.mode mode=(ble_setup|wifi_only) ble=([01])",
            "operation=boot.mode mode=ble_setup ble=1",
        )
        self.suite.uart.reset.return_value = 17
        self.suite.uart.wait.side_effect = [boot, None]

        result = self.suite.initial_commissioning()

        self.assertEqual(result["boot_mode"], "ble_setup")
        self.assertEqual(result["commissioning_source"], "empty_nvs")
        self.assertFalse(result["ble_recovery"])
        self.assertEqual(self.suite.uart.wait.call_count, 2)

    def test_initial_commissioning_accepts_saved_wifi_recovery(self):
        pattern = r"operation=boot.mode mode=(ble_setup|wifi_only) ble=([01])"
        boot = re.search(pattern, "operation=boot.mode mode=wifi_only ble=0")
        recovery_start = re.search(
            r"operation=wifi.got_ip ip=([0-9.]+)|"
            r"operation=ble.recovery outcome=starting reason=WIFI_UNAVAILABLE",
            "operation=ble.recovery outcome=starting reason=WIFI_UNAVAILABLE",
        )
        recovery_advertising = re.search(
            r"operation=ble.recovery outcome=advertising mode=commissioning",
            "operation=ble.recovery outcome=advertising mode=commissioning",
        )
        self.suite.uart.reset.return_value = 29
        self.suite.uart.wait.side_effect = [boot, None, recovery_start, recovery_advertising]

        result = self.suite.initial_commissioning()

        self.assertEqual(result["boot_mode"], "wifi_only")
        self.assertEqual(result["commissioning_source"], "wifi_failure_recovery")
        self.assertTrue(result["ble_recovery"])
        self.assertEqual(self.suite.uart.wait.call_count, 4)
        self.assertEqual(
            self.suite.uart.wait.call_args_list[2].args[0],
            r"operation=wifi.got_ip ip=([0-9.]+)|"
            r"operation=ble.recovery outcome=starting reason=WIFI_UNAVAILABLE",
        )
        self.assertEqual(
            self.suite.uart.wait.call_args_list[3].args[0],
            r"operation=ble.recovery outcome=advertising mode=commissioning",
        )

    def test_initial_commissioning_rejects_inconsistent_boot_transport(self):
        boot = re.search(
            r"operation=boot.mode mode=(ble_setup|wifi_only) ble=([01])",
            "operation=boot.mode mode=wifi_only ble=1",
        )
        self.suite.uart.wait.return_value = boot

        with self.assertRaisesRegex(AssertionError, "HIL_WIFI_BOOT_BLE_MISMATCH"):
            self.suite.initial_commissioning()

    def test_initial_commissioning_uses_udp_when_saved_wifi_is_already_connected(self):
        boot = re.search(
            r"operation=boot.mode mode=(ble_setup|wifi_only) ble=([01])",
            "operation=boot.mode mode=wifi_only ble=0",
        )
        got_ip = re.search(
            r"operation=wifi.got_ip ip=([0-9.]+)",
            "operation=wifi.got_ip ip=192.138.1.2",
        )
        status_line = (
            "$STATUS:bt=0,wifi=connected,ip=192.138.1.2,flash=0,stream=0,"
            "camera=1,sensor=0,psram=8388608,frames=1,errors=0,"
            "notify_errors=0,heap=100000,min_heap=90000"
        )
        self.suite.uart.reset.return_value = 41
        self.suite.uart.mark.return_value = 99
        self.suite.uart.text.return_value = (
            "operation=boot.mode mode=wifi_only ble=0\\n"
            "operation=boot.ready camera=1\\n"
            "operation=wifi.got_ip ip=192.138.1.2\\n"
            "UDP socket bound on port 8888\\n"
        )
        self.suite.uart.wait.side_effect = [boot, None, got_ip, None]
        receiver = Mock()
        receiver.request_control.side_effect = ["$CMD:keepalive", status_line]
        receiver.last_control_echo_seen = True
        with patch.object(self.suite, "receiver", return_value=receiver):
            result = self.suite.initial_commissioning()

        self.assertEqual(self.suite.phase, "wifi")
        self.assertIs(self.suite.udp, receiver)
        self.assertEqual(result["commissioning_source"], "saved_wifi")
        self.assertEqual(result["ip"], "192.138.1.2")
        self.assertFalse(result["ble_recovery"])
        self.assertEqual(receiver.request_control.call_args_list[0].args,
                         (bytes([0x0C]), "$CMD:keepalive"))
        self.assertEqual(receiver.request_control.call_args_list[1].args,
                         (bytes([0x09]), "$STATUS:"))

    def test_att_value_and_length_rejections_are_recognized(self):
        for name, message in (("org.bluez.Error.Failed", "Operation failed with ATT error: 0x13"),
                              ("org.bluez.Error.InvalidArguments", "Invalid Length")):
            with self.subTest(name=name):
                self.client.write.side_effect = FakeDBusError(name, message)
                self.suite.rejected_write(b"\x0a1111", "HIL_ACCEPTED")

    def test_transport_failures_never_count_as_rejection(self):
        for name, message in (("org.bluez.Error.Failed", "Not connected"),
                              ("org.bluez.Error.Failed", "Failed to initiate write"),
                              ("org.freedesktop.DBus.Error.NoReply", "Timed out")):
            with self.subTest(name=name, message=message):
                self.client.write.side_effect = FakeDBusError(name, message)
                with self.assertRaisesRegex(AssertionError, "HIL_BLE_REJECTION_TRANSPORT_ERROR"):
                    self.suite.rejected_write(b"\x0a1111", "HIL_ACCEPTED")

    def test_accepted_invalid_write_fails(self):
        with self.assertRaisesRegex(AssertionError, "HIL_ACCEPTED"):
            self.suite.rejected_write(b"\x0a1111", "HIL_ACCEPTED")

    def test_reboot_guard_requires_exact_error_and_live_setup(self):
        self.client.line.return_value = "$ERROR:WIFI_CONFIG_REQUIRED"
        self.client.status.return_value = {"bt": "1", "camera": "1", "errors": "0",
                                           "notify_errors": "0", "heap": "100000",
                                           "wifi": "disconnected"}
        self.suite.uart.text.return_value = "operation=command.error code=WIFI_CONFIG_REQUIRED"
        self.suite.reboot_without_credentials()
        self.client.command.assert_called_once_with(0x0B)
        self.client.status.assert_called_once()

    def test_reboot_guard_missing_reply_and_reset_fail(self):
        self.client.line.side_effect = TimeoutError("HIL_REPLY_TIMEOUT")
        with self.assertRaisesRegex(TimeoutError, "HIL_REPLY_TIMEOUT"):
            self.suite.reboot_without_credentials()
        self.client.line.side_effect = None
        self.client.line.return_value = "$ERROR:WIFI_CONFIG_REQUIRED"
        self.suite.uart.text.return_value = "rst:0xc (SW_CPU_RESET)"
        with self.assertRaisesRegex(AssertionError, "HIL_REBOOT_WITHOUT_CREDENTIALS"):
            self.suite.reboot_without_credentials()

    def test_none_is_not_passing_evidence(self):
        with self.assertRaisesRegex(AssertionError, "HIL_CASE_MISSING_EVIDENCE"):
            self.suite.case("missing", lambda: None)
        self.assertFalse(self.suite.records[0]["ok"])

    def test_failure_keeps_its_error_code(self):
        def fail():
            raise TimeoutError("HIL_REAL_FAILURE")
        with self.assertRaisesRegex(TimeoutError, "HIL_REAL_FAILURE"):
            self.suite.case("failure", fail)
        self.assertEqual(self.suite.records[0]["code"], "HIL_REAL_FAILURE")

    def test_udp_failure_records_received_fragment_evidence_without_pass(self):
        receiver = object.__new__(UdpFrames)
        receiver.datagrams = 3
        receiver.packets = 2
        receiver.total = 4
        receiver.parts = {0: b"private frame bytes", 2: b"private frame bytes"}
        receiver.dropped_frames = 1
        self.suite.udp = receiver
        with self.assertRaisesRegex(TimeoutError, "HIL_UDP_FRAME_TIMEOUT"):
            self.suite.case("udp_failure", lambda: (_ for _ in ()).throw(
                TimeoutError("HIL_UDP_FRAME_TIMEOUT")))
        record = self.suite.records[0]
        self.assertFalse(record["ok"])
        self.assertEqual(record["transport_evidence"], {
            "udp_datagrams": 3, "accepted_fragments": 2, "expected_fragments": 4,
            "received_sequences": [0, 2], "incomplete_frames": 1,
        })

    def test_wifi_status_uses_udp_control_not_ble_or_uart(self):
        self.suite.phase = "wifi"
        self.suite.udp = Mock()
        self.suite.udp.request_control.return_value = STATUS
        self.assertEqual(self.suite.status()["wifi"], "connected")
        self.suite.udp.request_control.assert_called_once_with(
            bytes([0x09]), "$STATUS:", timeout=2, attempts=4,
        )
        self.client.status.assert_not_called()
        self.suite.uart.wait.assert_not_called()

    def test_wifi_timeout_is_failure_not_skip(self):
        with patch("hardware_e2e.time.monotonic", side_effect=(0, WIFI_TIMEOUT + 1)):
            with self.assertRaisesRegex(TimeoutError, "HIL_WIFI_CONNECT_TIMEOUT"):
                self.suite.wait_wifi()

    def test_missing_credentials_fail_before_ble_write(self):
        self.suite.wifi = None
        with self.assertRaisesRegex(AssertionError, "HIL_WIFI_CREDENTIALS_REQUIRED"):
            self.suite.wifi_connect()
        self.client.pair.assert_not_called()

    def test_boundary_and_standby_checks_precede_wifi_transition(self):
        names = []
        self.suite.case = lambda name, function: names.append(name)
        self.suite.run()
        transition = names.index("wifi_provisioning")
        for name in ("wifi_maximum_payload", "wifi_reconfiguration_and_erase",
                     "restart_and_erased_nvs", "standby_and_resume", "pairing_authorization"):
            self.assertLess(names.index(name), transition)
        self.assertEqual(names[transition + 1:], ["udp_single_frame", "udp_stream_and_pause",
                                                "udp_single_after_pause", "udp_controls_and_peer_handover",
                                                "restart_and_nvs_recovery", "final_integrity"])

    def test_no_credentials_do_not_run_wifi_cases(self):
        self.suite.wifi = None
        names = []
        self.suite.case = lambda name, function: names.append(name)
        self.suite.run()
        self.assertNotIn("wifi_provisioning", names)
        self.assertNotIn("udp_single_frame", names)
        self.assertIn("final_integrity", names)

    def test_failed_config_cleanup_never_resends_or_erases_credentials(self):
        self.suite.wifi_dirty = True
        self.client.rx = object()
        self.suite.provision = Mock()
        self.suite.case = Mock(side_effect=TimeoutError("HIL_REPLY_TIMEOUT"))
        with self.assertRaisesRegex(TimeoutError, "HIL_REPLY_TIMEOUT"):
            self.suite.run()
        self.suite.provision.assert_not_called()
        self.client.pair.assert_not_called()
        self.client.wifi_erase.assert_not_called()
        self.client.disconnect.assert_called_once()
        self.assertTrue(self.suite.wifi_dirty)

    def test_wifi_boot_rejects_ble_start(self):
        self.suite.uart.wait.return_value = re.search(r"(192\.168\.1\.2)", "192.168.1.2")
        self.suite.uart.text.return_value = "operation=ble.init outcome=success"
        with self.assertRaisesRegex(AssertionError, "HIL_BLE_STARTED_IN_WIFI_MODE"):
            self.suite.verify_wifi_boot(0)

    def test_restart_requires_a_real_udp_frame(self):
        self.suite.udp = Mock()
        self.suite.verify_wifi_boot = Mock(return_value="192.168.1.2")
        with patch("hardware_e2e.UdpFrames") as receiver:
            receiver.return_value.next_frame.side_effect = TimeoutError("HIL_UDP_FRAME_TIMEOUT")
            with self.assertRaisesRegex(TimeoutError, "HIL_UDP_FRAME_TIMEOUT"):
                self.suite.restart()
        self.suite.uart.reset.assert_called_once()


class WifiRetryTests(unittest.TestCase):
    ATTEMPTS = 2
    PER_ATTEMPT_SECONDS = 40

    def evidence(self, extra="", failed=True, attempts=None):
        total = self.ATTEMPTS if attempts is None else attempts
        text = ("rst:0x1 (POWERON_RESET)\n"
                "operation=boot.mode mode=wifi_only ble=0\n"
                "operation=boot.ready camera=1\n")
        for attempt in range(1, total + 1):
            text += (f"operation=wifi.connect_attempt attempt={attempt} outcome=started\n"
                     "operation=wifi.disconnect reason=201\n")
        if failed:
            text += "$STATUS:bt=0,wifi=failed,camera=1\n"
        return text + extra

    def check(self, text, exhausted=True):
        uart = Mock()
        client = Mock(spec=["pump", "assert_not_advertising"])
        uart.text.return_value = text
        def wait(pattern, since, timeout=None, code="HIL_UART_REPLY_TIMEOUT"):
            self.assertEqual(since, 100)
            match = re.search(pattern, text)
            if match is None:
                raise TimeoutError(code)
            return match
        uart.wait.side_effect = wait
        def wait_count(pattern, count, since, timeout, code):
            self.assertEqual(since, 100)
            observed = len(re.findall(pattern, text))
            if observed < count:
                raise TimeoutError(code)
            return observed
        uart.wait_count.side_effect = wait_count
        result = missing_ap_evidence(uart, client, 100, self.ATTEMPTS,
                                     self.PER_ATTEMPT_SECONDS, exhausted)
        if exhausted:
            client.pump.assert_called_once_with(self.PER_ATTEMPT_SECONDS)
        else:
            client.pump.assert_not_called()
        client.assert_not_advertising.assert_called_once()
        return result

    def test_exhaustion_requires_all_failures_and_observation_window(self):
        result = self.check(self.evidence())
        self.assertEqual(result["attempts"], [1, 2])
        self.assertEqual(result["no_ap_failures"], self.ATTEMPTS)
        self.assertTrue(result["retry_exhausted"])

    def test_post_reset_cycle_does_not_claim_exhaustion(self):
        result = self.check(self.evidence(failed=False), exhausted=False)
        self.assertFalse(result["retry_exhausted"])

    def test_missing_failed_status_is_not_exhaustion(self):
        with self.assertRaisesRegex(TimeoutError, "HIL_RETRY_EXHAUSTION_NOT_OBSERVED"):
            self.check(self.evidence(failed=False))

    def test_missing_failure_cannot_pass(self):
        text = self.evidence().replace("operation=wifi.disconnect reason=201\n", "", 1)
        with self.assertRaisesRegex(TimeoutError, "HIL_NO_AP_FAILURE_NOT_OBSERVED"):
            self.check(text)

    def test_full_scale_retry_snapshot_waits_for_fragmented_twentieth_failure(self):
        uart = UARTLog("unused-test-uart", Path("unused-test-uart.log"))
        uart.data.extend(b"stale boot must not count\n")
        since = uart.mark()
        text = self.evidence(failed=False, attempts=20)
        last_failure = "operation=wifi.disconnect reason=201\n"
        prefix, _, _ = text.rpartition(last_failure)
        uart.data.extend(prefix.encode())
        pending = deque([b"operation=wifi.disconnect reason=", b"201\n",
                         b"$STATUS:bt=0,wifi=failed,camera=1\n"])
        clock = [0.0]

        def sleep(seconds):
            clock[0] += seconds
            if pending:
                uart.data.extend(pending.popleft())

        client = Mock(spec=["pump", "assert_not_advertising"])
        with patch("hardware_helpers.time.monotonic", side_effect=lambda: clock[0]), \
             patch("hardware_helpers.time.sleep", side_effect=sleep):
            result = missing_ap_evidence(uart, client, since, 20,
                                         self.PER_ATTEMPT_SECONDS, True)
        self.assertEqual(result["attempts"], list(range(1, 21)))
        self.assertEqual(result["no_ap_failures"], 20)
        self.assertFalse(pending)

    def test_extra_attempt_after_exhaustion_fails(self):
        with self.assertRaisesRegex(AssertionError, "HIL_RETRY_SEQUENCE_MISMATCH"):
            self.check(self.evidence(attempts=3))

    def test_fresh_boot_evidence_is_required(self):
        cases = (("rst:0x1 (POWERON_RESET)\n", "HIL_REBOOT_NOT_OBSERVED"),
                 ("operation=boot.mode mode=wifi_only ble=0\n", "HIL_WIFI_ONLY_BOOT_MISSING"),
                 ("operation=boot.ready camera=1\n", "HIL_CAMERA_BOOT_FAILED"))
        for line, code in cases:
            with self.subTest(code=code), self.assertRaisesRegex(TimeoutError, code):
                self.check(self.evidence().replace(line, ""))

    def test_ble_connection_and_runtime_faults_fail(self):
        cases = (("operation=ble.init", "HIL_BLE_STARTED_IN_WIFI_MODE"),
                 ("operation=wifi.got_ip", "HIL_MISSING_AP_WAS_REACHABLE"),
                 ("Guru Meditation", "HIL_UART_RUNTIME_FAULT"),
                 ("rst:0xc (SW_CPU_RESET)", "HIL_UNEXPECTED_RESET"))
        for text, code in cases:
            with self.subTest(code=code), self.assertRaisesRegex(AssertionError, code):
                self.check(self.evidence(extra=text))

    def test_retry_settings_are_read_from_firmware_config(self):
        with patch("wifi_retry_hil.Path.read_text", return_value=(
                "#define WIFI_MAX_RETRIES 3\n#define WIFI_CONNECT_TIMEOUT_MS 2000\n"
                "#define WIFI_RETRY_INTERVAL_MS 1000\n")):
            self.assertEqual(retry_settings(), (3, 3))

    def test_missing_or_invalid_retry_settings_fail(self):
        for config, code in (("", "HIL_RETRY_CONFIG_MISSING"),
                             ("#define WIFI_MAX_RETRIES 0\n", "HIL_RETRY_CONFIG_INVALID")):
            with self.subTest(code=code), patch("wifi_retry_hil.Path.read_text", return_value=config):
                with self.assertRaisesRegex(AssertionError, code):
                    retry_settings()


class BootSmokeTests(unittest.TestCase):
    def boot(self, mode, extras=""):
        return (f"rst:0x1 (POWERON_RESET)\noperation=boot.mode mode={mode}\n"
                "operation=camera.boot_capture jpeg=valid\n"
                f"operation=boot.ready camera=1 sensor=0 psram=8388608 version={VERSION}\n"
                + extras).encode()

    def test_valid_setup_boot(self):
        data = self.boot("ble_setup", "operation=ble.advertise\n")
        self.assertTrue(verify_boot(data, VERSION)["ok"])

    def test_setup_boot_rejects_wifi_start(self):
        data = self.boot("ble_setup", "operation=ble.advertise\noperation=wifi.start\n")
        self.assertIn("BOOT_WIFI_STARTED_DURING_SETUP", verify_boot(data, VERSION)["codes"])

    def test_wifi_boot_does_not_require_ble(self):
        self.assertTrue(verify_boot(self.boot("wifi_only"), VERSION, "wifi_only")["ok"])

    def test_wifi_boot_rejects_ble(self):
        data = self.boot("wifi_only", "operation=ble.init\n")
        self.assertIn("BOOT_BLE_STARTED_IN_WIFI_MODE", verify_boot(data, VERSION, "wifi_only")["codes"])

    def test_wrong_mode_fails(self):
        self.assertIn("BOOT_MODE_MISMATCH", verify_boot(self.boot("wifi_only"), VERSION)["codes"])


if __name__ == "__main__":
    unittest.main()
