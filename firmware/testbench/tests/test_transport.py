import threading
import unittest
from unittest.mock import patch

from testbench.engine import HardwareEngine
from testbench.errors import TestbenchError
from testbench.tests.bluez_stub import FIXTURE_PASSWORD, FIXTURE_SSID, WAIT_SECONDS, actual_bluez
from testbench.transport import WIRE


class CooperativeWriteTests(unittest.TestCase):
    def setUp(self):
        self.engine = HardwareEngine()
        self.engine.owner = threading.get_ident()
        self.addCleanup(self.engine.close)

    def test_actual_write_checks_cancellation_before_dbus_call(self):
        with actual_bluez(self.engine) as fixture:
            self.engine.cancelled.set()
            with self.assertRaises(TestbenchError) as caught:
                fixture.client.write(bytes([WIRE.CMD_CONNECTION_STATUS]))
            self.assertEqual(caught.exception.code, "TB_CANCELLED")
            self.assertEqual(fixture.writes, [])

    def test_actual_wifi_method_checks_at_immediate_write_boundary(self):
        with actual_bluez(self.engine) as fixture:
            original = fixture.client.write

            def cancel_at_boundary(data):
                self.engine.cancelled.set()
                return original(data)

            with patch.object(fixture.client, "write", side_effect=cancel_at_boundary), \
                    self.assertRaises(TestbenchError) as caught:
                fixture.client.wifi_config_put(FIXTURE_SSID, FIXTURE_PASSWORD)
            self.assertEqual(caught.exception.code, "TB_CANCELLED")
            self.assertEqual(fixture.writes, [])

    def test_actual_write_checks_cancellation_after_inflight_call(self):
        with actual_bluez(self.engine) as fixture:
            fixture.during_write = lambda _: self.engine.cancelled.set()
            with self.assertRaises(TestbenchError) as caught:
                fixture.client.write(bytes([WIRE.CMD_CONNECTION_STATUS]))
            self.assertEqual(caught.exception.code, "TB_CANCELLED")
            self.assertEqual(len(fixture.writes), 1)

    def test_real_write_enforces_owner_before_touching_dbus(self):
        with actual_bluez(self.engine) as fixture:
            errors = []

            def wrong_thread():
                try:
                    fixture.client.write(bytes([WIRE.CMD_CONNECTION_STATUS]))
                except TestbenchError as error:
                    errors.append(error.code)

            thread = threading.Thread(target=wrong_thread)
            thread.start()
            thread.join(WAIT_SECONDS)
            self.assertFalse(thread.is_alive())
            self.assertEqual(errors, ["TB_HARDWARE_THREAD_VIOLATION"])
            self.assertEqual(fixture.writes, [])

    def test_actual_wifi_ack_and_identity_parse_still_succeed(self):
        with actual_bluez(self.engine) as fixture:
            self.engine._setup({"ssid": FIXTURE_SSID, "password": FIXTURE_PASSWORD}, reboot=False)
            self.assertEqual([entry["code"] for entry in fixture.writes], [WIRE.CMD_WIFI_CONFIG_PUT])
            self.assertTrue(fixture.writes[0]["uncertain"])
            self.assertEqual(self.engine.snapshot()["phase"], "provisioned")
            self.assertEqual(fixture.client.esp_mac, "AA:BB:CC:DD:EE:FF")


if __name__ == "__main__":
    unittest.main()
