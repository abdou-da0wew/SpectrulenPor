"""Actual WiFi handler and maintenance transitions, without radios or NVS access."""

import unittest
from pathlib import Path

from session_host import FIRMWARE_ROOT, HostSessionHarness


class WifiStateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = FIRMWARE_ROOT / "components/wifi/wifi.c"
        source = path.read_text()
        source = source[source.index('static const char *TAG'):]
        stubs = Path(__file__).with_name("wifi_state_host.c")
        harness = stubs.read_text().replace("/* ACTUAL_WIFI */", source)
        cls.host = HostSessionHarness(cls, "wifi-state", harness, [path,
            FIRMWARE_ROOT / "components/wifi/wifi.h",
            FIRMWARE_ROOT / "components/protocol/protocol.c",
            FIRMWARE_ROOT / "components/protocol/protocol.h", FIRMWARE_ROOT / "config.h",
            stubs, Path(__file__), Path(__file__).with_name("session_host.py")])

    def test_got_ip_wins_before_timeout_claim(self):
        self.host.assert_case(self, "got_ip_before_timeout")

    def test_timeout_wins_before_late_got_ip(self):
        self.host.assert_case(self, "got_ip_during_timeout_disconnect")

    def test_got_ip_after_disconnect_does_not_restore_connection(self):
        self.host.assert_case(self, "got_ip_after_disconnect")

    def test_got_ip_after_stop_does_not_restore_or_reset_attempts(self):
        self.host.assert_case(self, "got_ip_after_stop")

    def test_got_ip_before_current_association_is_rejected(self):
        self.host.assert_case(self, "got_ip_without_association")

    def test_stop_restart_waits_for_driver_start_event(self):
        self.host.assert_case(self, "restart_event_order")

    def test_timeout_waits_for_disconnect_before_next_attempt(self):
        self.host.assert_case(self, "timeout_disconnect_order")

    def test_exact_twenty_attempt_exhaustion(self):
        self.host.assert_case(self, "twenty_attempts")

    def test_success_resets_attempts_and_disconnect_retries(self):
        self.host.assert_case(self, "success_then_disconnect")

    def test_connect_failure_does_not_overwrite_success(self):
        self.host.assert_case(self, "connect_return_after_success")

    def test_stopped_maintenance_performs_no_driver_calls(self):
        self.host.assert_case(self, "stopped")

    def test_timeout_driver_failure_does_not_deadlock(self):
        self.host.assert_case(self, "disconnect_failure")

    def test_late_lost_ip_cannot_pin_failed_disconnect(self):
        self.host.assert_case(self, "disconnect_failure_lost_ip")


if __name__ == "__main__":
    unittest.main()
