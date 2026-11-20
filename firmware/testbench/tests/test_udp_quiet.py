import unittest
from collections import deque
from types import SimpleNamespace
from unittest.mock import Mock, patch

from testbench.engine import HardwareEngine
from testbench.errors import TestbenchError
from testbench.settings import QUIET_SECONDS
from testbench.transport import Reassembler, WIRE


PEER = ("192.0.2.10", WIRE.UDP_PORT)


class ReassemblerEchoTests(unittest.TestCase):
    def test_runtime_command_echoes_are_not_protocol_errors(self):
        commands = (
            WIRE.CMD_STREAM_OFF,
            WIRE.CMD_STREAM_ON,
            WIRE.CMD_SINGLE_FRAME,
            WIRE.CMD_FLASH_ON,
            WIRE.CMD_FLASH_OFF,
            WIRE.CMD_RESTART,
            WIRE.CMD_SHUTDOWN,
            WIRE.CMD_CONNECTION_STATUS,
            WIRE.CMD_REBOOT,
            WIRE.CMD_UDP_KEEPALIVE,
        )
        receiver = Reassembler(PEER)

        for command in commands:
            with self.subTest(command=command):
                self.assertIsNone(receiver.feed(bytes([command]), PEER))

        self.assertEqual(receiver.protocol_errors, 0)
        self.assertEqual(receiver.packets, 0)
        self.assertEqual(receiver.parity_packets, 0)

    def test_setup_only_command_echo_is_not_accepted(self):
        receiver = Reassembler(PEER)

        self.assertIsNone(receiver.feed(bytes([WIRE.CMD_WIFI_CONFIG_PUT]), PEER))
        self.assertEqual(receiver.protocol_errors, 1)

    def test_duplicated_runtime_acknowledgements_and_status_are_control_plane(self):
        receiver = Reassembler(PEER)

        for packet in (
            b"$CMD:stream_off\n",
            b"$CMD:stream_off\r\n",
            b"$CMD:single_frame\n",
            b"$CMD:flash_on\n",
            b"$STATUS:bt=0,wifi=connected,stream=0\n",
        ):
            with self.subTest(packet=packet):
                self.assertIsNone(receiver.feed(packet, PEER))

        self.assertEqual(receiver.protocol_errors, 0)
        self.assertEqual(receiver.packets, 0)
        self.assertEqual(receiver.parity_packets, 0)

    def test_unknown_runtime_acknowledgement_is_rejected(self):
        receiver = Reassembler(PEER)

        self.assertIsNone(receiver.feed(b"$CMD:untrusted\n", PEER))
        self.assertEqual(receiver.protocol_errors, 1)


class QuietWindowTests(unittest.TestCase):
    def make_engine(self, udp):
        engine = object.__new__(HardwareEngine)
        engine.udp = udp
        engine.client = None
        engine.cooperate = Mock()
        engine._udp_metrics = Mock()
        return engine

    def run_quiet(self, engine):
        now = [0.0]

        def monotonic():
            value = now[0]
            now[0] += 0.1
            return value

        with (
            patch("testbench.engine.time.monotonic", side_effect=monotonic),
            patch("testbench.engine.time.sleep"),
        ):
            engine._quiet()

    def test_duplicate_control_ack_does_not_count_as_resumed_video(self):
        assembly = SimpleNamespace(packets=4, parity_packets=1)
        udp = SimpleNamespace(
            assembly=assembly,
            ready=deque(),
            datagrams=10,
            poll=Mock(side_effect=lambda: setattr(udp, "datagrams", udp.datagrams + 1)),
        )
        engine = self.make_engine(udp)

        self.run_quiet(engine)

        self.assertGreater(udp.datagrams, 10)
        engine._udp_metrics.assert_called_once()

    def test_new_video_fragment_fails_quiet_window(self):
        assembly = SimpleNamespace(packets=4, parity_packets=1)
        udp = SimpleNamespace(
            assembly=assembly,
            ready=deque(),
            datagrams=10,
        )

        def receive_video():
            assembly.packets += 1

        udp.poll = Mock(side_effect=receive_video)
        engine = self.make_engine(udp)
        now = [0.0]

        def monotonic():
            value = now[0]
            now[0] += 0.1
            return value

        with (
            patch("testbench.engine.time.monotonic", side_effect=monotonic),
            patch("testbench.engine.time.sleep"),
            self.assertRaisesRegex(TestbenchError, "^HIL_UDP_UNEXPECTED_FRAGMENTS$"),
        ):
            engine._quiet()


class ControlAcknowledgementTests(unittest.TestCase):
    def make_engine(self, code):
        udp = SimpleNamespace(request_control=Mock(), command=Mock())
        engine = object.__new__(HardwareEngine)
        engine.udp = udp
        engine.client = None
        engine._control(code)
        return udp

    def test_stream_off_waits_for_firmware_ack(self):
        udp = self.make_engine(WIRE.CMD_STREAM_OFF)

        udp.request_control.assert_called_once_with(
            bytes([WIRE.CMD_STREAM_OFF]), "$CMD:stream_off", timeout=4, attempts=3
        )
        udp.command.assert_not_called()

    def test_single_frame_is_not_retried_after_a_lost_ack(self):
        udp = self.make_engine(WIRE.CMD_SINGLE_FRAME)

        udp.request_control.assert_called_once_with(
            bytes([WIRE.CMD_SINGLE_FRAME]), "$CMD:single_frame", timeout=4, attempts=1
        )
        udp.command.assert_not_called()


class StreamStopStateVerificationTests(unittest.TestCase):
    def make_engine(self, acknowledgment, status_response):
        udp = SimpleNamespace(
            request_control=Mock(return_value=status_response),
            command=Mock(),
        )
        engine = object.__new__(HardwareEngine)
        engine.udp = udp
        engine.client = None
        engine._control = Mock(side_effect=acknowledgment)
        return engine, udp

    def test_missing_ack_is_recovered_by_confirmed_stream_zero_status(self):
        engine, udp = self.make_engine(
            TimeoutError("HIL_UDP_CONTROL_TIMEOUT"),
            "$STATUS:bt=0,wifi=connected,stream=0",
        )

        engine._stop_stream()

        engine._control.assert_called_once_with(WIRE.CMD_STREAM_OFF)
        udp.request_control.assert_called_once_with(
            bytes([WIRE.CMD_CONNECTION_STATUS]),
            "$STATUS:",
            timeout=4,
            attempts=3,
            required_status_copies=1,
        )

    def test_stream_one_status_rejects_a_lost_stop_command(self):
        engine, _ = self.make_engine(
            TimeoutError("HIL_UDP_CONTROL_TIMEOUT"),
            "$STATUS:bt=0,wifi=connected,stream=1",
        )

        with self.assertRaisesRegex(
            TestbenchError, "^HIL_UDP_STREAM_STOP_UNCONFIRMED$"
        ):
            engine._stop_stream()

    def test_missing_ack_and_missing_status_keep_the_timeout_failure(self):
        engine, udp = self.make_engine(
            TimeoutError("HIL_UDP_CONTROL_TIMEOUT"),
            None,
        )
        udp.request_control.side_effect = TimeoutError("HIL_UDP_CONTROL_TIMEOUT")

        with self.assertRaisesRegex(TimeoutError, "^HIL_UDP_CONTROL_TIMEOUT$"):
            engine._stop_stream()


if __name__ == "__main__":
    unittest.main()
