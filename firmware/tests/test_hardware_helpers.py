"""Hardware-free regressions for BLE acknowledgments, UART logs and UDP frames."""

import struct
import sys
import unittest
from collections import deque
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import hardware_helpers as helpers


TEST_EPOCH = 1000.0
TEST_TIMEOUT = 0.05
TEST_PEER = ("192.0.2.10", 8888)
TEST_JPEG = b"\xff\xd8" + b"x" * 2396 + b"\xff\xd9"


class FakeClock:
    def __init__(self):
        self.now = TEST_EPOCH

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class ClockedTestCase(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        for name in ("monotonic", "sleep"):
            patcher = patch.object(helpers.time, name, side_effect=getattr(self.clock, name))
            patcher.start()
            self.addCleanup(patcher.stop)


def make_bluez_client():
    """Skip BlueZ initialization; only allocate the notification parser's state."""
    client = object.__new__(helpers.BluezClient)
    client.lines = deque()
    client.frames = deque()
    client.buffer = bytearray()
    client.notifications = 0
    client.max_notification_bytes = 0
    client.completed_frames = 0
    client.protocol_errors = 0
    client.esp_mac = None
    client.esp_hostname = None
    client.paired = False
    client.write = Mock(name="write")
    client.pump = Mock(name="pump")
    return client


def notify(client, data):
    client._notification(helpers.CHARACTERISTIC, {"Value": data}, [])


def notification_pump(client, chunks):
    pending = deque(chunks)

    def pump(seconds=0.0):
        if pending:
            notify(client, pending.popleft())

    return Mock(name="pump", side_effect=pump)


class BluezNotificationTests(ClockedTestCase):
    def setUp(self):
        super().setUp()
        self.client = make_bluez_client()

    def test_fragmented_and_coalesced_lines_strip_delimiters(self):
        wire = (b"$CMD:paired\r\n$ESP_MAC:AA:BB:CC:DD:EE:FF\n"
                b"$ESP_NAME:test-camera\r\n")
        expected = ["$CMD:paired", "$ESP_MAC:AA:BB:CC:DD:EE:FF",
                    "$ESP_NAME:test-camera"]

        for split in range(1, len(wire)):
            with self.subTest(split=split):
                client = make_bluez_client()
                notify(client, wire[:split])
                notify(client, wire[split:])

                self.assertEqual([line for _, line in client.lines], expected)
                self.assertEqual(client.buffer, bytearray())
                self.assertIs(client.paired, True)
                self.assertEqual(client.esp_mac, "AA:BB:CC:DD:EE:FF")
                self.assertEqual(client.esp_hostname, "test-camera")
                self.assertEqual(client.protocol_errors, 0)

    def test_pairing_requires_a_complete_exact_notification(self):
        notify(self.client, b"$CMD:paired_pending\n$CMD:paired\r")
        self.assertIs(self.client.paired, False)
        self.assertEqual([line for _, line in self.client.lines], ["$CMD:paired_pending"])

        notify(self.client, b"\n")

        self.assertIs(self.client.paired, True)
        self.assertEqual(self.client.lines[-1][1], "$CMD:paired")

    def test_esp_identity_is_updated_from_fresh_notifications(self):
        self.client.esp_mac = "00:00:00:00:00:00"
        self.client.esp_hostname = "old-camera"
        self.client.lines.extend([
            (TEST_EPOCH - 1, "$ESP_MAC:00:00:00:00:00:00"),
            (TEST_EPOCH - 1, "$ESP_NAME:old-camera"),
        ])
        self.client.pump = notification_pump(self.client, [
            b"$ESP_MAC:AA:BB:CC:DD:EE:FF\r\n$ESP_NAME:new-camera\n",
        ])

        self.assertEqual(self.client.line("$ESP_MAC:", TEST_EPOCH, TEST_TIMEOUT),
                         "$ESP_MAC:AA:BB:CC:DD:EE:FF")
        self.assertEqual(self.client.line("$ESP_NAME:", TEST_EPOCH, TEST_TIMEOUT),
                         "$ESP_NAME:new-camera")
        self.assertEqual(self.client.esp_mac, "AA:BB:CC:DD:EE:FF")
        self.assertEqual(self.client.esp_hostname, "new-camera")
        self.assertEqual(len(self.client.lines), 2)
        self.assertTrue(all(stamp < TEST_EPOCH for stamp, _ in self.client.lines))

    def test_fragmented_jpeg_and_coalesced_text_are_kept_separate(self):
        notify(self.client, b"\xff")
        notify(self.client, TEST_JPEG[1:-1])
        self.assertFalse(self.client.frames)

        notify(self.client, TEST_JPEG[-1:] + b"$STATUS:camera=1\r\n")

        self.assertEqual(list(self.client.frames), [(TEST_EPOCH, TEST_JPEG)])
        self.assertEqual(list(self.client.lines), [(TEST_EPOCH, "$STATUS:camera=1")])
        self.assertEqual(self.client.completed_frames, 1)
        self.assertEqual(self.client.buffer, bytearray())

    def test_stale_ack_is_not_consumed_instead_of_fresh_ack(self):
        stale = (TEST_EPOCH - 1, "$CMD:paired")
        self.client.lines.append(stale)
        self.client.pump = notification_pump(self.client, [b"$CMD:paired\n"])

        result = self.client.line("$CMD:paired", TEST_EPOCH, TEST_TIMEOUT)

        self.assertEqual(result, "$CMD:paired")
        self.assertEqual(list(self.client.lines), [stale])

    def test_stale_ack_alone_times_out(self):
        self.client.lines.append((TEST_EPOCH - 1, "$CMD:paired"))

        with self.assertRaisesRegex(TimeoutError, "^HIL_REPLY_TIMEOUT$"):
            self.client.line("$CMD:paired", TEST_EPOCH, TEST_TIMEOUT)

        self.assertEqual(len(self.client.lines), 1)

    def test_command_ack_does_not_match_a_similar_prefix(self):
        for ack in ("$CMD:paired", "$CMD:reboot", "$CMD:wifi_config_received"):
            for suffix in ("_pending", ":error", " "):
                with self.subTest(ack=ack, suffix=suffix):
                    client = make_bluez_client()
                    since = self.clock.now
                    similar = (since, ack + suffix)
                    client.lines.extend([similar, (since, ack)])

                    self.assertEqual(client.line(ack, since, TEST_TIMEOUT), ack)
                    self.assertEqual(list(client.lines), [similar])

                    with self.assertRaisesRegex(TimeoutError, "^HIL_REPLY_TIMEOUT$"):
                        client.line(ack, since, TEST_TIMEOUT)

    def test_requested_ack_newline_suffix_is_normalized(self):
        for suffix in ("\n", "\r\n", "\r", "\r\n\r\n"):
            with self.subTest(suffix=repr(suffix)):
                client = make_bluez_client()
                client.lines.append((TEST_EPOCH, "$CMD:paired"))

                self.assertEqual(client.line("$CMD:paired" + suffix,
                                             TEST_EPOCH, TEST_TIMEOUT), "$CMD:paired")
                self.assertFalse(client.lines)

    def test_data_reply_still_matches_a_normalized_prefix(self):
        self.client.lines.append((TEST_EPOCH, "$STATUS:bt=1,camera=1"))

        self.assertEqual(self.client.line("$STATUS:\r\n", TEST_EPOCH, TEST_TIMEOUT),
                         "$STATUS:bt=1,camera=1")


class BluezCommandTests(ClockedTestCase):
    def test_pair_reboot_and_erase_require_their_ack(self):
        cases = (
            ("pair", b"\x0a11111", "$CMD:paired"),
            ("reboot", b"\x0b", "$CMD:reboot"),
            ("wifi_erase", b"\x07\0\0", "$CMD:wifi_config_received"),
        )
        for method, payload, ack in cases:
            with self.subTest(method=method):
                client = make_bluez_client()
                client.pump = notification_pump(client, [ack.encode() + b"\r\n"])

                self.assertIs(getattr(client, method)(timeout=TEST_TIMEOUT), True)
                client.write.assert_called_once_with(payload)
                if method == "pair":
                    self.assertIs(client.paired, True)

    def test_pair_reboot_and_erase_do_not_swallow_timeouts(self):
        cases = (
            ("pair", b"\x0a11111", "$CMD:paired"),
            ("reboot", b"\x0b", "$CMD:reboot"),
            ("wifi_erase", b"\x07\0\0", "$CMD:wifi_config_received"),
        )
        for method, payload, ack in cases:
            with self.subTest(method=method):
                client = make_bluez_client()
                failure = TimeoutError("HIL_REPLY_TIMEOUT")
                client.line = Mock(side_effect=failure)

                with self.assertRaises(TimeoutError) as caught:
                    getattr(client, method)(timeout=TEST_TIMEOUT)

                self.assertIs(caught.exception, failure)
                client.write.assert_called_once_with(payload)
                client.line.assert_called_once_with(ack, TEST_EPOCH, TEST_TIMEOUT)
                self.assertIs(client.paired, False)

    def test_max_wifi_payload_is_one_write_and_returns_wire_byte_length(self):
        for ssid in ("S" * 32, "\u00e9" * 16):
            with self.subTest(ssid_bytes=len(ssid.encode()), multibyte=not ssid.isascii()):
                client = make_bluez_client()
                password = "a" * 64
                payload = b"\x07" + ssid.encode() + b"\0" + password.encode() + b"\0"
                client.pump = notification_pump(client, [b"$CMD:wifi_config_received\n"])

                length = client.wifi_config_put(ssid, password, timeout=TEST_TIMEOUT)

                self.assertEqual(length, 99)
                self.assertEqual(length, len(payload))
                client.write.assert_called_once_with(payload)

    def test_wifi_timeout_propagates_without_resending(self):
        client = make_bluez_client()
        client.lines.extend([
            (TEST_EPOCH - 1, "$CMD:wifi_config_received"),
            (TEST_EPOCH, "$CMD:wifi_config_received_pending"),
        ])

        with self.assertRaisesRegex(TimeoutError, "^HIL_REPLY_TIMEOUT$"):
            client.wifi_config_put("TestAP", "TestPass123", timeout=TEST_TIMEOUT)

        client.write.assert_called_once_with(b"\x07TestAP\0TestPass123\0")
        self.assertEqual(len(client.lines), 2)


class UARTLogTests(ClockedTestCase):
    def setUp(self):
        super().setUp()
        self.log = helpers.UARTLog("unused-test-uart", Path("unused-test-uart.log"))

    def append_log(self, data):
        with self.log.lock:
            self.log.data.extend(data)

    def test_mark_and_text_are_immutable_snapshots(self):
        old = b"operation=boot.ready camera=1\n"
        fresh = b"operation=wifi.connect result=ok\n"
        self.append_log(old)
        mark = self.log.mark()
        snapshot = self.log.text(mark)

        self.append_log(fresh)

        self.assertIsInstance(mark, int)
        self.assertEqual(mark, len(old))
        self.assertEqual(snapshot, "")
        self.assertEqual(self.log.text(mark), fresh.decode())
        self.assertEqual(self.log.text(), (old + fresh).decode())

    def test_wait_cannot_succeed_from_a_stale_log(self):
        self.append_log(b"operation=wifi.connect result=old\n")
        mark = self.log.mark()

        with self.assertRaisesRegex(TimeoutError, "^HIL_UART_REPLY_TIMEOUT$"):
            self.log.wait(r"operation=wifi\.connect result=(\w+)", mark,
                          timeout=TEST_TIMEOUT)

    def test_wait_keeps_the_original_mark_across_fragmented_fresh_log(self):
        self.append_log(b"operation=wifi.connect result=old\n")
        mark = self.log.mark()
        pending = deque([b"operation=wifi.", b"connect result=fresh\n"])

        def pump():
            if pending:
                self.append_log(pending.popleft())

        fake_pump = Mock(side_effect=pump)
        match = self.log.wait(r"operation=wifi\.connect result=(\w+)", mark,
                              timeout=TEST_TIMEOUT, pump=fake_pump)

        self.assertEqual(match.group(1), "fresh")
        self.assertEqual(fake_pump.call_count, 2)
        self.assertEqual(mark, len(b"operation=wifi.connect result=old\n"))

    def test_wait_raises_the_requested_timeout_code(self):
        with self.assertRaisesRegex(TimeoutError, "^HIL_TEST_UART_TIMEOUT$"):
            self.log.wait("never received", self.log.mark(), timeout=TEST_TIMEOUT,
                          code="HIL_TEST_UART_TIMEOUT")

    def test_capture_error_fails_even_if_a_matching_log_exists(self):
        self.append_log(b"operation=boot.ready\n")
        self.log.error = "OSError"

        with self.assertRaisesRegex(AssertionError, "^HIL_UART_CAPTURE_ERROR$"):
            self.log.wait(r"operation=boot\.ready", 0, timeout=TEST_TIMEOUT)

    def test_uart_read_failure_is_recorded_and_wait_fails_explicitly(self):
        self.log.uart = Mock(in_waiting=0)
        self.log.uart.read.side_effect = OSError("test UART disconnected")
        self.log.output = Mock()

        self.log._read()

        self.assertEqual(self.log.error, "OSError")
        self.log.output.write.assert_not_called()
        with self.assertRaisesRegex(AssertionError, "^HIL_UART_CAPTURE_ERROR$"):
            self.log.wait("never received", 0, timeout=TEST_TIMEOUT)

    def test_twentieth_failure_waits_on_nineteen_without_nested_repetition(self):
        failure = b"operation=wifi.disconnect reason=201\n"
        self.append_log(failure * 19)
        pending = deque([b"operation=wifi.disconnect reason=", b"201\n"])

        def pump():
            if pending:
                self.append_log(pending.popleft())

        self.assertEqual(self.log.wait_count(r"operation=wifi.disconnect reason=201\b",
                                             20, 0, TEST_TIMEOUT, pump=pump), 20)

    def test_nineteen_failures_cannot_pass_twenty_attempt_evidence(self):
        self.append_log(b"operation=wifi.disconnect reason=201\n" * 19)
        with self.assertRaisesRegex(TimeoutError, "^HIL_NO_AP_FAILURE_NOT_OBSERVED$"):
            self.log.wait_count(r"operation=wifi.disconnect reason=201\b", 20, 0,
                                TEST_TIMEOUT, "HIL_NO_AP_FAILURE_NOT_OBSERVED")

    def test_count_ignores_stale_and_similar_failures(self):
        self.append_log(b"operation=wifi.disconnect reason=201\n")
        mark = self.log.mark()
        self.append_log(b"operation=wifi.disconnect reason=2010\n")
        with self.assertRaises(TimeoutError):
            self.log.wait_count(r"operation=wifi.disconnect reason=201\b", 1, mark, TEST_TIMEOUT)


class UARTLifecycleTests(unittest.TestCase):
    """No serial device, reader thread or evidence file is opened by these tests."""

    def setUp(self):
        self.log = helpers.UARTLog("unused-test-uart", Path("unused-test-uart.log"))
        self.output = Mock(spec=["write", "flush", "close"])
        self.uart = Mock(spec=["port", "dtr", "rts", "open", "close"])
        self.thread = Mock(spec=["start", "join", "ident"], ident=1)
        self.serial = Mock(return_value=self.uart)
        patches = (
            patch.dict(sys.modules, {"serial": SimpleNamespace(Serial=self.serial)}),
            patch.object(Path, "mkdir"),
            patch.object(Path, "open", return_value=self.output),
            patch.object(helpers.threading, "Thread", return_value=self.thread),
        )
        for patcher in patches:
            patcher.start()
            self.addCleanup(patcher.stop)

    def test_serial_constructor_failure_closes_the_evidence_file(self):
        failure = OSError("fixture constructor failure")
        self.serial.side_effect = failure
        with self.assertRaises(OSError) as caught:
            self.log.__enter__()
        self.assertIs(caught.exception, failure)
        self.output.close.assert_called_once()
        self.thread.start.assert_not_called()

    def test_open_failure_closes_uart_and_output_without_starting_reader(self):
        failure = OSError("fixture open failure")
        self.uart.open.side_effect = failure
        with self.assertRaises(OSError) as caught:
            self.log.__enter__()
        self.assertIs(caught.exception, failure)
        self.uart.close.assert_called_once()
        self.output.close.assert_called_once()
        self.thread.start.assert_not_called()

    def test_failed_thread_start_closes_every_resource_without_joining_unstarted_thread(self):
        self.thread.ident = None
        self.thread.start.side_effect = RuntimeError("fixture thread failure")
        with self.assertRaisesRegex(RuntimeError, "^fixture thread failure$"):
            self.log.__enter__()
        self.thread.join.assert_not_called()
        self.uart.close.assert_called_once()
        self.output.close.assert_called_once()

    def test_reader_finishes_before_uart_and_output_are_closed(self):
        calls = Mock()
        calls.attach_mock(self.thread.join, "join")
        calls.attach_mock(self.uart.close, "uart_close")
        calls.attach_mock(self.output.close, "output_close")
        with self.log:
            self.assertFalse(self.log.stopped.is_set())
        self.assertTrue(self.log.stopped.is_set())
        self.thread.join.assert_called_once_with()
        self.assertEqual([call[0] for call in calls.mock_calls], ["join", "uart_close", "output_close"])

    def line_failure(self, line):
        class Serial:
            def __init__(self):
                self.fail = False
                self.lines = []
                self.open = Mock()
                self.close = Mock()

            def __setattr__(self, name, value):
                if name in ("dtr", "rts"):
                    self.lines.append(name)
                    if self.fail and name == line:
                        raise OSError("fixture line failure")
                object.__setattr__(self, name, value)

        uart = Serial()
        self.serial.return_value = uart
        return uart

    def test_either_line_failure_still_releases_both_resources_and_reports_failure(self):
        for line in ("dtr", "rts"):
            with self.subTest(line=line):
                self.log = helpers.UARTLog("unused-test-uart", Path("unused-test-uart.log"))
                self.output.reset_mock()
                uart = self.line_failure(line)
                self.log.__enter__()
                uart.fail = True
                with self.assertRaisesRegex(RuntimeError, "^HIL_UART_CLEANUP_INCOMPLETE$"):
                    self.log.__exit__(None, None, None)
                self.assertEqual(uart.lines[-2:], ["dtr", "rts"])
                uart.close.assert_called_once()
                self.output.close.assert_called_once()
                self.assertEqual(self.log.cleanup_errors, ["OSError"])

    def test_line_failure_during_entry_does_not_leak_or_mask_original_failure(self):
        uart = self.line_failure("dtr")
        uart.fail = True
        with self.assertRaisesRegex(OSError, "^fixture line failure$"):
            self.log.__enter__()
        uart.close.assert_called_once()
        self.output.close.assert_called_once()
        self.thread.start.assert_not_called()

    def test_uart_close_failure_does_not_skip_output_close(self):
        self.log.__enter__()
        self.uart.close.side_effect = OSError("fixture close failure")
        with self.assertRaisesRegex(RuntimeError, "^HIL_UART_CLEANUP_INCOMPLETE$"):
            self.log.__exit__(None, None, None)
        self.output.close.assert_called_once()
        self.assertEqual(self.log.cleanup_errors, ["OSError"])

    def test_output_close_failure_is_not_reported_as_success(self):
        self.log.__enter__()
        self.output.close.side_effect = OSError("fixture output failure")
        with self.assertRaisesRegex(RuntimeError, "^HIL_UART_CLEANUP_INCOMPLETE$"):
            self.log.__exit__(None, None, None)
        self.uart.close.assert_called_once()
        self.assertEqual(self.log.cleanup_errors, ["OSError"])

    def test_original_operation_failure_survives_cleanup_failure(self):
        original = TimeoutError("HIL_ORIGINAL_FAILURE")
        self.uart.close.side_effect = OSError("fixture close failure")
        with self.assertRaises(TimeoutError) as caught:
            with self.log:
                raise original
        self.assertIs(caught.exception, original)
        self.output.close.assert_called_once()
        self.assertEqual(self.log.cleanup_errors, ["OSError"])

    def test_original_entry_failure_survives_output_cleanup_failure(self):
        original = OSError("fixture open failure")
        self.uart.open.side_effect = original
        self.output.close.side_effect = OSError("fixture output failure")
        with self.assertRaises(OSError) as caught:
            self.log.__enter__()
        self.assertIs(caught.exception, original)
        self.uart.close.assert_called_once()
        self.output.close.assert_called_once()
        self.assertEqual(self.log.cleanup_errors, ["OSError"])

    def test_successful_cleanup_is_idempotent(self):
        self.log.__enter__()
        self.log.__exit__(None, None, None)
        self.log.__exit__(None, None, None)
        self.uart.close.assert_called_once()
        self.output.close.assert_called_once()
        self.thread.join.assert_called_once()


class FakeDBusError(Exception):
    def __init__(self, name):
        self.name = name

    def get_dbus_name(self):
        return self.name


class BluezDisconnectTests(ClockedTestCase):
    DEVICE_PATH = "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"

    def client(self, objects):
        client = make_bluez_client()
        client.device_path = self.DEVICE_PATH
        client.manager = Mock()
        client.manager.GetManagedObjects.return_value = objects
        client.bus = Mock()
        client.dbus = Mock(DBusException=FakeDBusError)
        client.dbus.Dictionary.side_effect = lambda values, **kwargs: values
        client.dbus.Array.side_effect = lambda values, **kwargs: values
        client.adapter = Mock()
        client.adapter_path = "/org/bluez/hci0"
        client.name = "SpectruLenPor-ESP32"
        client.signal = Mock()
        client.tx = client.rx = object()
        client.paired = True
        return client

    def test_disappeared_entry_clears_local_authorization_without_dbus_call(self):
        client = self.client({})
        signal = client.signal
        client.disconnect()
        client.bus.get_object.assert_not_called()
        signal.remove.assert_called_once()
        self.assertFalse(client.paired)
        self.assertIsNone(client.rx)
        self.assertIsNone(client.device_path)

    def test_absent_object_race_is_accepted_only_after_managed_objects_check(self):
        connected = {self.DEVICE_PATH: {helpers.DEVICE: {"Connected": True}}}
        client = self.client(connected)
        client.manager.GetManagedObjects.side_effect = [connected, {}]
        client.dbus.Interface.return_value.Disconnect.side_effect = FakeDBusError(
            "org.freedesktop.DBus.Error.UnknownObject")
        client.disconnect()
        self.assertIsNone(client.device_path)
        self.assertFalse(client.paired)

    def test_present_object_or_transport_failure_is_not_suppressed(self):
        connected = {self.DEVICE_PATH: {helpers.DEVICE: {"Connected": True}}}
        for name in ("org.freedesktop.DBus.Error.UnknownObject", "org.bluez.Error.Failed",
                     "org.freedesktop.DBus.Error.NoReply"):
            with self.subTest(name=name):
                client = self.client(connected)
                client.dbus.Interface.return_value.Disconnect.side_effect = FakeDBusError(name)
                with self.assertRaises(FakeDBusError):
                    client.disconnect()
                self.assertFalse(client.paired)
                self.assertIsNone(client.rx)

    def test_negative_scan_handles_cached_entry_disappearing_before_remove(self):
        cached = {self.DEVICE_PATH: {helpers.DEVICE: {"Connected": False}}}
        client = self.client(cached)
        snapshots = deque([cached])
        client.manager.GetManagedObjects.side_effect = lambda: snapshots.popleft() if snapshots else {}
        client.adapter.RemoveDevice.side_effect = FakeDBusError("org.bluez.Error.DoesNotExist")
        client.assert_not_advertising(TEST_TIMEOUT)
        client.adapter.StartDiscovery.assert_called_once()
        client.adapter.StopDiscovery.assert_called_once()
        self.assertIsNone(client.device_path)

    def test_negative_scan_does_not_hide_adapter_failure(self):
        cached = {self.DEVICE_PATH: {helpers.DEVICE: {"Connected": False}}}
        client = self.client(cached)
        client.adapter.RemoveDevice.side_effect = FakeDBusError("org.freedesktop.DBus.Error.NoReply")
        with self.assertRaises(FakeDBusError):
            client.assert_not_advertising(TEST_TIMEOUT)
        client.adapter.StartDiscovery.assert_not_called()


class PacketSocket:
    def __init__(self, packets):
        self.pending = deque(packets)
        self.receive_sizes = []
        self.sent = []

    def sendto(self, data, peer):
        self.sent.append((data, peer))
        return len(data)

    def recvfrom(self, size):
        self.receive_sizes.append(size)
        if not self.pending:
            raise BlockingIOError
        return self.pending.popleft()


def udp_packet(seq, total, offset, payload, size=None, frame_id=1,
               frame_size=None, parity=False):
    if size is None:
        size = len(payload)
    if frame_size is None:
        frame_size = total * helpers.UDP_PAYLOAD_BYTES
    raw_seq = (helpers.UDP_PARITY_SEQUENCE_FLAG | seq) if parity else seq
    return helpers.UDP_HEADER.pack(raw_seq, total, offset, size, frame_id, frame_size) + payload


def jpeg_packets(frame=TEST_JPEG, frame_id=1):
    total = (len(frame) + helpers.UDP_PAYLOAD_BYTES - 1) // helpers.UDP_PAYLOAD_BYTES
    packets = [
        (udp_packet(seq, total, seq * helpers.UDP_PAYLOAD_BYTES,
                    frame[seq * helpers.UDP_PAYLOAD_BYTES:(seq + 1) * helpers.UDP_PAYLOAD_BYTES],
                    frame_id=frame_id, frame_size=len(frame)), TEST_PEER)
        for seq in range(total)
    ]
    group_size = helpers.udp_fec_group_size(total)
    for group_index in range(min(total, group_size)):
        parity = bytearray(helpers.UDP_PAYLOAD_BYTES)
        for seq in range(group_index, total, group_size):
            offset = seq * helpers.UDP_PAYLOAD_BYTES
            chunk = frame[offset:offset + helpers.UDP_PAYLOAD_BYTES]
            for index, value in enumerate(chunk):
                parity[index] ^= value
        packets.append((udp_packet(
            group_index, total, group_index * helpers.UDP_PAYLOAD_BYTES,
            bytes(parity), frame_id=frame_id, frame_size=len(frame), parity=True,
        ), TEST_PEER))
    return [packet for packet, _ in packets]



def make_udp_receiver(packets):
    receiver = object.__new__(helpers.UdpFrames)
    receiver.peer = TEST_PEER
    receiver.socket = PacketSocket(packets)
    receiver.parts = {}
    receiver.parity = {}
    receiver.total = 0
    receiver.frame_size = 0
    receiver.frame_id = None
    receiver.last_frame_id = None
    receiver.dropped_frames = 0
    receiver.stale_datagrams = 0
    receiver.packets = 0
    receiver.parity_packets = 0
    receiver.datagrams = 0
    receiver.control_messages = []
    receiver.last_control_echo_seen = False
    receiver.background_video_datagrams = 0
    return receiver


class UdpFrameTests(ClockedTestCase):
    def test_wire_contract_is_v2_six_uint32_fields_and_mtu_sized_chunks(self):
        self.assertEqual(helpers.UDP_HEADER.size, 24)
        self.assertEqual(helpers.UDP_HEADER.format, "<IIIIII")
        self.assertEqual(helpers.UDP_PAYLOAD_BYTES, 1448)
        self.assertEqual(helpers.UDP_FEC_GROUP_SIZE, 4)
        self.assertEqual(helpers.UDP_HEADER.unpack(
            helpers.UDP_HEADER.pack(1, 2, 1448, 88, 7, 1488)),
            (1, 2, 1448, 88, 7, 1488))

    def test_udp_peer_echo_requires_exact_payload_and_source(self):
        receiver = make_udp_receiver([(b"\x0c", TEST_PEER)])
        receiver.wait_echo(b"\x0c", timeout=TEST_TIMEOUT)
        self.assertEqual(receiver.datagrams, 1)

        receiver = make_udp_receiver([(b"\x01", TEST_PEER)])
        with self.assertRaisesRegex(AssertionError, "^HIL_UDP_ECHO_MISMATCH$"):
            receiver.wait_echo(b"\x0c", timeout=TEST_TIMEOUT)

        receiver = make_udp_receiver([(b"\x0c", ("192.0.2.11", TEST_PEER[1]))])
        with self.assertRaisesRegex(AssertionError, "^HIL_UDP_SOURCE$"):
            receiver.wait_echo(b"\x0c", timeout=TEST_TIMEOUT)

    def test_reads_udp_status_control_line_from_expected_peer(self):
        line = b"$STATUS:bt=0,wifi=connected,ip=192.0.2.10\n"
        receiver = make_udp_receiver([(line, TEST_PEER)])

        result = receiver.control_line("$STATUS:", timeout=TEST_TIMEOUT)

        self.assertEqual(result, "$STATUS:bt=0,wifi=connected,ip=192.0.2.10")
        self.assertEqual(receiver.datagrams, 1)

    def test_request_control_ignores_optional_peer_echo_like_flutter(self):
        receiver = make_udp_receiver([
            (bytes([helpers.CMD_UDP_KEEPALIVE]), TEST_PEER),
            (b"$CMD:keepalive\n", TEST_PEER),
        ])

        result = receiver.request_control(
            bytes([helpers.CMD_UDP_KEEPALIVE]), "$CMD:keepalive",
            timeout=TEST_TIMEOUT, attempts=1,
        )

        self.assertEqual(result, "$CMD:keepalive")
        self.assertEqual(receiver.datagrams, 2)

    def test_request_control_accepts_registration_echo_before_ack(self):
        receiver = make_udp_receiver([
            (bytes([helpers.CMD_UDP_KEEPALIVE]), TEST_PEER),
            (b"$CMD:keepalive\n", TEST_PEER),
        ])

        result = receiver.request_control(
            bytes([helpers.CMD_UDP_KEEPALIVE]), "$CMD:keepalive",
            timeout=TEST_TIMEOUT, attempts=2,
            echo=bytes([helpers.CMD_UDP_KEEPALIVE]),
        )

        self.assertEqual(result, "$CMD:keepalive")
        self.assertTrue(receiver.last_control_echo_seen)
        self.assertEqual(receiver.datagrams, 2)
        self.assertEqual(receiver.socket.sent, [(bytes([helpers.CMD_UDP_KEEPALIVE]), TEST_PEER)])

    def test_status_wait_returns_latest_of_delayed_duplicate_snapshots(self):
        old_status = b"$STATUS:bt=0,wifi=connected,flash=1,stream=1\n"
        new_status = b"$STATUS:bt=0,wifi=connected,flash=0,stream=1\n"
        receiver = make_udp_receiver([
            (old_status, TEST_PEER),
            (new_status, TEST_PEER),
            (new_status, TEST_PEER),
        ])
        result = receiver.request_control(
            bytes([helpers.CMD_CONNECTION_STATUS]), "$STATUS:",
            timeout=TEST_TIMEOUT, attempts=1,
        )
        self.assertIn("flash=0", result)
        self.assertEqual(receiver.datagrams, 2)

    def test_control_wait_skips_valid_interleaved_video_datagrams(self):
        status = b"$STATUS:bt=0,wifi=connected,camera=1,heap=100\n"
        video = jpeg_packets(frame_id=44)[0]
        receiver = make_udp_receiver([
            (video, TEST_PEER), (status, TEST_PEER), (status, TEST_PEER),
        ])
        result = receiver.request_control(
            bytes([helpers.CMD_CONNECTION_STATUS]), "$STATUS:",
            timeout=TEST_TIMEOUT, attempts=1,
        )
        self.assertTrue(result.startswith("$STATUS:"))
        self.assertEqual(receiver.background_video_datagrams, 1)
        self.assertEqual(receiver.control_messages, [])

    def test_control_wait_rejects_malformed_video_datagrams(self):
        malformed = bytearray(jpeg_packets(frame_id=44)[0])
        malformed[8:12] = (1).to_bytes(4, "little")
        receiver = make_udp_receiver([(bytes(malformed), TEST_PEER)])
        with self.assertRaisesRegex(AssertionError, "^HIL_UDP_UNEXPECTED_CONTROL$"):
            receiver.request_control(
                bytes([helpers.CMD_CONNECTION_STATUS]), "$STATUS:",
                timeout=TEST_TIMEOUT, attempts=1,
            )

    def test_request_control_accepts_ack_before_registration_echo(self):
        receiver = make_udp_receiver([
            (b"$CMD:keepalive\n", TEST_PEER),
            (bytes([helpers.CMD_UDP_KEEPALIVE]), TEST_PEER),
        ])

        result = receiver.request_control(
            bytes([helpers.CMD_UDP_KEEPALIVE]), "$CMD:keepalive",
            timeout=TEST_TIMEOUT, attempts=2,
            echo=bytes([helpers.CMD_UDP_KEEPALIVE]),
        )

        self.assertEqual(result, "$CMD:keepalive")
        self.assertTrue(receiver.last_control_echo_seen)
        self.assertEqual(receiver.datagrams, 2)

    def test_request_control_retries_idempotent_command_after_lost_reply(self):
        receiver = make_udp_receiver([
            (bytes([helpers.CMD_UDP_KEEPALIVE]), TEST_PEER),
        ])

        def delayed_reply(data, peer):
            receiver.socket.sent.append((data, peer))
            if len(receiver.socket.sent) == 2:
                receiver.socket.pending.append((b"$CMD:keepalive\n", TEST_PEER))
            return len(data)

        receiver.socket.sendto = delayed_reply
        result = receiver.request_control(
            bytes([helpers.CMD_UDP_KEEPALIVE]), "$CMD:keepalive",
            timeout=TEST_TIMEOUT, attempts=2,
            echo=bytes([helpers.CMD_UDP_KEEPALIVE]),
        )

        self.assertEqual(result, "$CMD:keepalive")
        self.assertEqual(len(receiver.socket.sent), 2)

    def test_request_control_skips_valid_delayed_command_ack_before_status(self):
        receiver = make_udp_receiver([
            (b"$CMD:flash_on\n", TEST_PEER),
            (b"$STATUS:bt=0,wifi=connected,ip=192.0.2.10\n", TEST_PEER),
        ])

        result = receiver.request_control(
            b"\x09", "$STATUS:", timeout=TEST_TIMEOUT, attempts=1,
        )

        self.assertTrue(result.startswith("$STATUS:"))
        self.assertEqual(receiver.control_messages, ["$CMD:flash_on"])
        self.assertEqual(receiver.datagrams, 2)

    def test_request_control_rejects_unknown_command_ack(self):
        receiver = make_udp_receiver([(b"$CMD:untrusted\n", TEST_PEER)])
        with self.assertRaisesRegex(AssertionError, "^HIL_UDP_UNKNOWN_ACK$"):
            receiver.request_control(b"\x09", "$STATUS:", timeout=TEST_TIMEOUT)

    def test_request_control_rejects_error_and_wrong_peer(self):
        receiver = make_udp_receiver([(b"$ERROR:WIFI_UNAVAILABLE\n", TEST_PEER)])
        with self.assertRaisesRegex(AssertionError, "^HIL_UDP_COMMAND_ERROR$"):
            receiver.request_control(b"\x09", "$STATUS:", timeout=TEST_TIMEOUT)

        receiver = make_udp_receiver([(b"$STATUS:ok\n", ("192.0.2.11", TEST_PEER[1]))])
        with self.assertRaisesRegex(AssertionError, "^HIL_UDP_SOURCE$"):
            receiver.request_control(b"\x09", "$STATUS:", timeout=TEST_TIMEOUT)

    def test_udp_control_line_rejects_unexpected_source_and_payload(self):
        receiver = make_udp_receiver([(b"$STATUS:ok\n", ("192.0.2.11", TEST_PEER[1]))])
        with self.assertRaisesRegex(AssertionError, "^HIL_UDP_SOURCE$"):
            receiver.control_line("$STATUS:", timeout=TEST_TIMEOUT)

        receiver = make_udp_receiver([(b"not-status\n", TEST_PEER)])
        with self.assertRaisesRegex(AssertionError, "^HIL_UDP_UNEXPECTED_CONTROL$"):
            receiver.control_line("$STATUS:", timeout=TEST_TIMEOUT)

    def test_reconstructs_out_of_order_fragments_without_ble(self):
        receiver = make_udp_receiver([(packet, TEST_PEER)
                                      for packet in reversed(jpeg_packets())])
        stamp, frame = receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(stamp, TEST_EPOCH)
        self.assertEqual(frame, TEST_JPEG)
        self.assertEqual(receiver.packets, 1)
        self.assertEqual(receiver.parity_packets, 1)
        self.assertEqual(receiver.datagrams, 2)
        self.assertEqual(receiver.parts, {})
        self.assertEqual(receiver.total, 0)
        self.assertEqual(receiver.socket.receive_sizes, [helpers.UDP_RECEIVE_BYTES] * 2)

    def test_late_fragment_after_fec_recovery_is_counted_as_stale(self):
        packets = jpeg_packets(frame_id=17)
        receiver = make_udp_receiver([(packet, TEST_PEER) for packet in packets[1:]])
        _, frame = receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(frame, TEST_JPEG)

        receiver.socket.pending.append((packets[0], TEST_PEER))
        with self.assertRaisesRegex(TimeoutError, "^HIL_UDP_FRAME_TIMEOUT$"):
            receiver.next_frame(timeout=TEST_TIMEOUT)

        self.assertEqual(receiver.stale_datagrams, 1)
        self.assertIsNone(receiver.frame_id)
        self.assertEqual(receiver.parts, {})

    def test_xor_fec_recovers_one_missing_data_packet(self):
        packets = jpeg_packets()
        receiver = make_udp_receiver([(packet, TEST_PEER) for packet in packets[1:]])
        _, frame = receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(frame, TEST_JPEG)
        self.assertEqual(receiver.packets, 1)
        self.assertEqual(receiver.parity_packets, 1)

    def test_two_adjacent_fragments_are_recovered_by_strided_fec_groups(self):
        frame = bytes((index * 13) & 0xFF for index in range(10 * helpers.UDP_PAYLOAD_BYTES + 17))
        packets = jpeg_packets(frame, frame_id=29)
        receiver = make_udp_receiver([
            (packet, TEST_PEER) for packet in packets
            if (helpers.UDP_HEADER.unpack_from(packet)[0] & helpers.UDP_PARITY_SEQUENCE_FLAG)
            or ((helpers.UDP_HEADER.unpack_from(packet)[0] & 0x7FFFFFFF) not in {0, 1})
        ])
        _, decoded = receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(decoded, frame)

    def test_two_losses_in_one_strided_group_are_not_recovered(self):
        frame = bytes((index * 7) & 0xFF for index in range(10 * helpers.UDP_PAYLOAD_BYTES + 17))
        packets = jpeg_packets(frame, frame_id=30)
        receiver = make_udp_receiver([
            (packet, TEST_PEER) for packet in packets
            if (helpers.UDP_HEADER.unpack_from(packet)[0] & helpers.UDP_PARITY_SEQUENCE_FLAG)
            or ((helpers.UDP_HEADER.unpack_from(packet)[0] & 0x7FFFFFFF) not in {0, 4})
        ])
        with self.assertRaisesRegex(TimeoutError, "^HIL_UDP_FRAME_TIMEOUT$"):
            receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertNotIn(0, receiver.parts)
        self.assertNotIn(4, receiver.parts)

    def test_optional_ble_client_is_pumped_while_receiving(self):
        receiver = make_udp_receiver([(packet, TEST_PEER) for packet in jpeg_packets()])
        client = Mock(spec=["pump"])
        _, frame = receiver.next_frame(client=client, timeout=TEST_TIMEOUT)
        self.assertEqual(frame, TEST_JPEG)
        self.assertEqual(client.pump.call_count, 2)

    def test_duplicate_status_replies_are_ignored_before_video(self):
        status = b"$STATUS:bt=0,wifi=connected,camera=1\\n"
        packets = [(status, TEST_PEER), (status, TEST_PEER)]
        packets.extend((packet, TEST_PEER) for packet in jpeg_packets())
        receiver = make_udp_receiver(packets)
        _, frame = receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(frame, TEST_JPEG)
        self.assertEqual(receiver.control_messages, ["$STATUS:bt=0,wifi=connected,camera=1"] * 2)

    def test_documented_single_byte_echoes_are_accepted_but_not_frame_data(self):
        packets = [(b"\x01", TEST_PEER), (b"\x02", TEST_PEER),
                   (bytes([helpers.CMD_UDP_KEEPALIVE]), TEST_PEER),
                   (b"$CMD:single_frame\n", TEST_PEER)]
        packets.extend((packet, TEST_PEER) for packet in jpeg_packets())
        receiver = make_udp_receiver(packets)
        _, frame = receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(frame, TEST_JPEG)
        self.assertEqual(receiver.datagrams, 6)
        self.assertEqual(receiver.packets, 2)
        self.assertEqual(receiver.control_messages, ["$CMD:single_frame"])

    def test_udp_error_ack_is_never_discarded_as_a_valid_control_message(self):
        receiver = make_udp_receiver([(b"$ERROR:WIFI_UNAVAILABLE\n", TEST_PEER)])
        with self.assertRaisesRegex(AssertionError, "^HIL_UDP_COMMAND_ERROR$"):
            receiver.next_frame(timeout=TEST_TIMEOUT)

    def test_wrong_source_address_or_port_is_rejected(self):
        for source in (("192.0.2.11", TEST_PEER[1]), (TEST_PEER[0], TEST_PEER[1] + 1)):
            receiver = make_udp_receiver([(jpeg_packets()[0], source)])
            with self.assertRaisesRegex(AssertionError, "^HIL_UDP_SOURCE$"):
                receiver.next_frame(timeout=TEST_TIMEOUT)
            self.assertEqual(receiver.parts, {})
            self.assertEqual(receiver.packets, 0)

    def test_drain_preserves_completed_frame_watermark_for_late_parity(self):
        receiver = make_udp_receiver([
            (packet, TEST_PEER) for packet in jpeg_packets(frame_id=7)
        ])
        _, frame = receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(frame, TEST_JPEG)
        self.assertEqual(receiver.last_frame_id, 7)

        receiver.drain()
        receiver.socket.pending.append((
            udp_packet(0, (len(TEST_JPEG) + helpers.UDP_PAYLOAD_BYTES - 1) // helpers.UDP_PAYLOAD_BYTES,
                       0, bytes(helpers.UDP_PAYLOAD_BYTES),
                       frame_id=7, frame_size=len(TEST_JPEG), parity=True),
            TEST_PEER,
        ))
        with self.assertRaisesRegex(TimeoutError, "^HIL_UDP_FRAME_TIMEOUT$"):
            receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertIsNone(receiver.frame_id)
        self.assertEqual(receiver.last_frame_id, 7)
        self.assertEqual(receiver.stale_datagrams, 1)

    def test_all_short_transport_echoes_are_ignored_like_flutter(self):
        short_packets = (b"", b"\x00", b"\x03", b"\xff", b"\x01\x02", bytes(23))
        packets = [(packet, TEST_PEER) for packet in short_packets]
        packets.extend((packet, TEST_PEER) for packet in jpeg_packets())
        receiver = make_udp_receiver(packets)
        _, frame = receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(frame, TEST_JPEG)
        # Frame assembly finishes as soon as all data fragments are present;
        # the trailing parity datagram is not required to complete the frame.
        self.assertEqual(receiver.datagrams, len(short_packets) + 2)

    def test_invalid_sequence_and_frame_metadata_are_rejected(self):
        cases = (
            udp_packet(0, 0, 0, b"x", frame_size=4),
            udp_packet(2, 3, 2800, b"x", frame_size=2401),
            udp_packet(0, 2, 0, b"x", frame_size=helpers.MAX_FRAME_BYTES + 1),
        )
        for packet in cases:
            receiver = make_udp_receiver([(packet, TEST_PEER)])
            with self.assertRaisesRegex(AssertionError, "^HIL_UDP_SEQUENCE$"):
                receiver.next_frame(timeout=TEST_TIMEOUT)

    def test_invalid_sizes_and_offsets_are_rejected(self):
        invalid = (
            udp_packet(0, 2, 0, b"", size=0, frame_size=2400),
            udp_packet(0, 2, 0, b"x" * 1401, size=1401, frame_size=2000),
            udp_packet(0, 2, 1, b"x", frame_size=2400),
            udp_packet(0, 2, 0, b"x", size=2, frame_size=2400),
            udp_packet(0, 2, 0, b"x", frame_size=2000),
            udp_packet(1, 2, 1000, b"x", frame_size=2000),
        )
        for packet in invalid:
            receiver = make_udp_receiver([(packet, TEST_PEER)])
            with self.assertRaises(AssertionError):
                receiver.next_frame(timeout=TEST_TIMEOUT)

    def test_incomplete_strided_group_with_two_losses_is_not_returned(self):
        frame = bytes((index * 11) & 0xFF for index in range(10 * helpers.UDP_PAYLOAD_BYTES + 17))
        packets = jpeg_packets(frame, frame_id=31)
        receiver = make_udp_receiver([
            (packet, TEST_PEER) for packet in packets
            if (helpers.UDP_HEADER.unpack_from(packet)[0] & helpers.UDP_PARITY_SEQUENCE_FLAG)
            or ((helpers.UDP_HEADER.unpack_from(packet)[0] & 0x7FFFFFFF) not in {0, 4})
        ])
        with self.assertRaisesRegex(TimeoutError, "^HIL_UDP_FRAME_TIMEOUT$"):
            receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(set(receiver.parts), {1, 2, 3, 5, 6, 7, 8, 9, 10})
        self.assertEqual(receiver.dropped_frames, 0)

    def test_newer_frame_replaces_partial_and_old_frame_is_ignored(self):
        old = jpeg_packets(TEST_JPEG, frame_id=10)
        fresh_frame = TEST_JPEG[:-1] + b"z"
        fresh = jpeg_packets(fresh_frame, frame_id=11)
        packets = [(old[0], TEST_PEER)]
        packets.extend((packet, TEST_PEER) for packet in fresh)
        packets.append((old[1], TEST_PEER))
        packets.append((old[2], TEST_PEER))
        receiver = make_udp_receiver(packets)
        _, frame = receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(frame, fresh_frame)
        self.assertEqual(receiver.dropped_frames, 1)

    def test_echoes_without_a_frame_eventually_time_out(self):
        receiver = make_udp_receiver([(b"\x01", TEST_PEER), (b"\x02", TEST_PEER)])
        with self.assertRaisesRegex(TimeoutError, "^HIL_UDP_FRAME_TIMEOUT$"):
            receiver.next_frame(timeout=TEST_TIMEOUT)
        self.assertEqual(receiver.datagrams, 2)
        self.assertEqual(receiver.packets, 0)

if __name__ == "__main__":
    unittest.main()
