"""Actual BLE/main queue, execution and notification boundaries with host spies."""

import unittest
from pathlib import Path

from session_host import FIRMWARE_ROOT, HostSessionHarness


class BleSessionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        ble_path = FIRMWARE_ROOT / "components/ble/ble.c"
        main_path = FIRMWARE_ROOT / "components/main/main.c"
        ble = ble_path.read_text()
        main = main_path.read_text()
        # Compile unchanged function bodies, not a reimplementation of the state machine.
        ble_state = ble[ble.index('static const char *TAG'):ble.index('static const struct ble_gatt_chr_def')]
        ble_send = ble[ble.index('esp_err_t ble_send_text('):ble.index('static void ble_advertise(void)\n{')]
        app = main[main.index('static const char *TAG'):main.index('\nvoid app_main(void)')]
        stubs = Path(__file__).with_name("ble_session_host.c")
        source = stubs.read_text().replace("/* ACTUAL_BLE_STATE */", ble_state).replace(
            "/* ACTUAL_BLE_SEND */", ble_send).replace("/* ACTUAL_MAIN */", app)
        cls.host = HostSessionHarness(cls, "ble-session", source, [ble_path, main_path,
            FIRMWARE_ROOT / "components/ble/ble.h", FIRMWARE_ROOT / "components/wifi/wifi.h",
            FIRMWARE_ROOT / "components/protocol/protocol.c",
            FIRMWARE_ROOT / "components/protocol/protocol.h", FIRMWARE_ROOT / "config.h",
            stubs, Path(__file__), Path(__file__).with_name("session_host.py")],
            extra_flags=("-pthread",))

    def test_new_stream_command_reconciles_before_execution(self):
        self.host.assert_case(self, "new_stream_during_drain")

    def test_new_flash_command_reconciles_before_execution(self):
        self.host.assert_case(self, "new_flash_during_drain")

    def test_stale_dequeued_command_has_no_side_effect(self):
        self.host.assert_case(self, "stale_at_execution")

    def test_reconnect_before_ack_does_not_reply_to_new_link(self):
        self.host.assert_case(self, "reconnect_before_ack")

    def test_reconnect_after_config_ack_suppresses_remaining_responses(self):
        self.host.assert_case(self, "reconnect_after_config_ack")

    def test_reconnect_before_config_ack_suppresses_all_responses(self):
        self.host.assert_case(self, "reconnect_before_config_ack")

    def test_reconnect_after_mac_suppresses_name_and_config(self):
        self.host.assert_case(self, "reconnect_after_mac")

    def test_reconnect_after_name_suppresses_config(self):
        self.host.assert_case(self, "reconnect_after_name")

    def test_reconnect_before_error_suppresses_error(self):
        self.host.assert_case(self, "reconnect_before_error")

    def test_reconnect_before_status_suppresses_status(self):
        self.host.assert_case(self, "reconnect_before_status")

    def test_reconnect_during_chunks_drops_old_tail(self):
        self.host.assert_case(self, "reconnect_during_chunks")

    def test_reused_handle_is_serialized_against_notify_submission(self):
        self.host.assert_case(self, "reconnect_at_mbuf_allocation")

    def test_closed_session_queue_is_discarded(self):
        self.host.assert_case(self, "stale_queue")

    def test_pairing_authorization_does_not_cross_connection(self):
        self.host.assert_case(self, "pairing_is_scoped")

    def test_config_byte_protocol_is_unchanged(self):
        self.host.assert_case(self, "config_responses")

    def test_notification_resource_retry_keeps_source_session(self):
        self.host.assert_case(self, "retry_reconnect")

    def test_captured_frame_is_bound_to_application_session(self):
        self.host.assert_case(self, "reconnect_before_capture")


if __name__ == "__main__":
    unittest.main()
