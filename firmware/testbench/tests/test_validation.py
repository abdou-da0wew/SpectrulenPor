import unittest

from testbench.errors import TestbenchError, safe_error
from testbench.validation import action_request, peer_ip, wifi_credentials


class ValidationTests(unittest.TestCase):
    def test_wifi_valid_boundaries(self):
        for credentials in (("A", ""), ("A" * 32, "a" * 64), ("test", "p" * 8),
                            ("test", "p" * 63), ("é" * 16, "é" * 4)):
            self.assertEqual(wifi_credentials(*credentials), credentials)

    def test_wifi_rejects_byte_overflow_nul_and_nonhex_64(self):
        cases = (("", "password"), ("é" * 17, "password"), ("a\0b", "password"),
                 ("test", "pass\0word"), ("test", "p" * 64), ("test", "p" * 7),
                 ("test", "é" * 33), (None, "password"), ("test", None),
                 ("\ud800", "password"))
        for credentials in cases:
            with self.subTest(credentials=credentials), self.assertRaises(TestbenchError):
                wifi_credentials(*credentials)

    def test_actions_require_actual_boolean(self):
        for value in (1, 0, "true", None, [], {}):
            with self.subTest(value=value), self.assertRaises(TestbenchError):
                action_request({"action": "stream", "params": {"enabled": value}})

    def test_unknown_fields_and_missing_action_rejected(self):
        cases = ({}, [], {"action": "erase"}, {"action": "connect", "params": []},
                 {"action": "connect", "password": "secret"},
                 {"action": "connect", "params": {"port": "elsewhere"}},
                 {"action": "stream"}, {"action": "setup"})
        for body in cases:
            with self.subTest(body=body), self.assertRaises(TestbenchError):
                action_request(body)

    def test_wifi_sources_exclusive(self):
        with self.assertRaises(TestbenchError):
            action_request({"action": "setup", "params": {"wifi_from_nm": True, "ssid": "test"}})

    def test_configuration_confirmation_required(self):
        for profile in ("full", "missing-ap"):
            with self.assertRaises(TestbenchError) as caught:
                action_request({"action": "test", "params": {"profile": profile}})
            self.assertEqual(caught.exception.code, "TB_CONFIRM_CONFIGURATION")

    def test_soak_duration_finite_and_bounded(self):
        for duration in (False, 0, -1, 3601, float("nan"), float("inf"), "10"):
            with self.subTest(duration=duration), self.assertRaises(TestbenchError):
                action_request({"action": "test", "params": {"profile": "soak", "duration": duration}})

    def test_dashboard_duration_alias_is_bounded_and_unambiguous(self):
        _, params = action_request({"action": "test", "params": {"profile": "soak", "duration_seconds": 10}})
        self.assertEqual(params["duration"], 10)
        with self.assertRaises(TestbenchError):
            action_request({"action": "test", "params": {"profile": "soak", "duration": 10, "duration_seconds": 10}})

    def test_peer_is_literal_unicast_ipv4(self):
        self.assertEqual(peer_ip("192.168.1.100"), "192.168.1.100")
        for ip in ("localhost", "::1", "0.0.0.0", "127.0.0.1", "224.1.1.1", "255.255.255.255", None):
            with self.subTest(ip=ip), self.assertRaises(TestbenchError):
                peer_ip(ip)

    def test_raw_errors_not_exposed(self):
        for error in (ValueError("password123 /private/path"), RuntimeError("secret"),
                      OSError("/dev/private")):
            public = safe_error(error).public()
            self.assertEqual(public["code"], "TB_HARDWARE_OPERATION_FAILED")
            self.assertNotIn("private", str(public))
        self.assertEqual(safe_error(TimeoutError("HIL_REPLY_TIMEOUT")).code, "HIL_REPLY_TIMEOUT")


if __name__ == "__main__":
    unittest.main()
