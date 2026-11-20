import json
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from testbench.engine import HardwareEngine
from testbench.errors import TestbenchError
from testbench.tests.bluez_stub import FIXTURE_PASSWORD, FIXTURE_SSID, WAIT_SECONDS, actual_bluez
from testbench.tests.fakes import FAKE_JPEG, FakeClient, FakeLock, fake_engine, wait_job
from testbench.transport import UdpReceiver, WIRE


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.engines = []

    def tearDown(self):
        for engine in self.engines:
            engine.close()
        self.assertFalse(FakeLock.held)

    def engine(self, **kwargs):
        engine = fake_engine(**kwargs)
        self.engines.append(engine)
        return engine

    def connect(self, engine):
        engine.submit({"action": "connect"})
        self.assertEqual(wait_job(engine)["status"], "passed")
        return engine.fake_clients[-1]

    def test_single_worker_owns_hardware_and_snapshots_are_copies(self):
        engine = self.engine()
        client = self.connect(engine)
        self.assertNotEqual(client.owner, threading.get_ident())
        self.assertEqual(client.owner, engine.owner)
        state = engine.snapshot()
        state["events"].clear()
        self.assertTrue(engine.snapshot()["events"])
        engine.submit({"action": "single"})
        self.assertEqual(wait_job(engine)["status"], "passed")
        self.assertEqual(engine.frame()[0], FAKE_JPEG)
        self.assertEqual(engine.snapshot()["metrics"]["frames"], 1)

    def test_busy_and_cooperative_cancel(self):
        engine = self.engine()
        entered = threading.Event()

        def factory(*arguments):
            client = FakeClient(*arguments)
            client.connect_wait = threading.Event()
            engine.fake_clients.append(client)
            entered.set()
            return client

        engine.client_factory = factory
        job = engine.submit({"action": "connect"})
        self.assertTrue(entered.wait(1))
        with self.assertRaises(TestbenchError) as caught:
            engine.submit({"action": "disconnect"})
        self.assertEqual(caught.exception.status, 409)
        self.assertEqual(engine.submit({"action": "cancel"}), job)
        self.assertEqual(wait_job(engine)["status"], "cancelled")
        self.assertEqual(engine.snapshot()["error"]["code"], "TB_CANCELLED")
        self.assertFalse(engine.snapshot()["connected"])
        self.assertFalse(FakeLock.held)

    def test_no_active_cancel_returns_conflict(self):
        with self.assertRaises(TestbenchError) as caught:
            self.engine().submit({"action": "cancel"})
        self.assertEqual(caught.exception.status, 409)

    def test_two_sessions_cannot_share_adapter(self):
        first, second = self.engine(), self.engine()
        self.connect(first)
        second.submit({"action": "connect"})
        self.assertEqual(wait_job(second)["error"]["code"], "TB_HARDWARE_LOCKED")
        self.assertEqual(first.snapshot()["phase"], "paired")

    def test_no_decoder_means_no_ready_state(self):
        engine = self.engine()
        self.connect(engine)
        engine.decoder = lambda data: (_ for _ in ()).throw(TestbenchError("TB_INVALID_JPEG"))
        engine.submit({"action": "single"})
        self.assertEqual(wait_job(engine)["status"], "failed")
        self.assertIsNone(engine.frame()[0])
        self.assertEqual(engine.snapshot()["metrics"]["frames"], 0)

    def test_attach_timeout_preserves_partial_packet_diagnostics(self):
        engine = self.engine()

        class FakeUDP:
            def __init__(self, ip, **kwargs):
                self.peer = (ip, WIRE.UDP_PORT)
                self.datagrams, self.packets, self.dropped_frames = 3, 2, 1
                self.assembly = SimpleNamespace(parts={0: b"chunk", 1: b"chunk"}, total=35, protocol_errors=1)

            def command(self, data):
                return

            def next_frame(self, **kwargs):
                raise TimeoutError("HIL_UDP_FRAME_TIMEOUT")

            def close(self):
                return

        engine.udp_factory = FakeUDP
        engine.submit({"action": "attach", "params": {"ip": "192.168.1.100"}})
        self.assertEqual(wait_job(engine)["status"], "failed")
        report = engine.report()
        self.assertEqual(report["receive_diagnostics"]["in_progress_chunks"], 2)
        self.assertEqual(report["receive_diagnostics"]["expected_chunks"], 35)
        self.assertEqual(report["metrics"]["datagrams"], 3)
        self.assertEqual(report["metrics"]["incomplete_frames"], 1)
        self.assertFalse(report["verifications"]["firmware"])

    def test_provision_ack_failure_never_resends_or_erases(self):
        engine = self.engine()
        client = self.connect(engine)
        client.fail_provision = True
        engine.submit({"action": "setup", "params": {"ssid": "test-network", "password": "test-password"}})
        self.assertEqual(wait_job(engine)["status"], "failed")
        self.assertEqual(client.provisions, 1)
        self.assertTrue(engine.report()["configuration_may_require_recovery"])
        self.assertEqual(client.commands, [WIRE.CMD_STREAM_OFF, WIRE.CMD_FLASH_OFF])
        self.assertNotIn("test-password", json.dumps(engine.report()))
        self.assertNotIn("test-network", json.dumps(engine.report()))

    def test_identity_failure_is_not_successful_provisioning(self):
        engine = self.engine()
        client = self.connect(engine)
        client.fail_identity = True
        engine.submit({"action": "setup", "params": {"ssid": "test-network", "password": "test-password"}})
        self.assertEqual(wait_job(engine)["status"], "failed")
        self.assertEqual(client.provisions, 1)
        self.assertTrue(engine.recovery_required)

    def test_recovery_blocks_retry_even_after_reconnect(self):
        engine = self.engine()
        client = self.connect(engine)
        client.fail_provision = True
        engine.submit({"action": "setup", "params": {"ssid": "test-network", "password": "test-password"}})
        wait_job(engine)
        self.connect(engine)
        with self.assertRaises(TestbenchError) as caught:
            engine.submit({"action": "setup", "params": {"ssid": "test-network", "password": "test-password"}})
        self.assertEqual(caught.exception.code, "TB_CONFIGURATION_RECOVERY_REQUIRED")
        self.assertEqual(client.provisions, 1)

    def test_good_setup_and_exact_reboot_disconnect(self):
        engine = self.engine()
        client = self.connect(engine)
        engine.submit({"action": "setup", "params": {"ssid": "test-network", "password": "test-password"}})
        self.assertEqual(wait_job(engine)["status"], "passed")
        self.assertEqual(engine.snapshot()["esp_mac"], "AA:BB:CC:DD:EE:FF")
        self.assertFalse(engine.snapshot()["connected"])
        self.assertEqual(engine.snapshot()["phase"], "rebooting")
        self.assertEqual(client.provisions, 1)
        self.assertEqual(client.commands.count(WIRE.CMD_REBOOT), 1)

    def test_invalid_credentials_never_queue_a_write(self):
        engine = self.engine()
        client = self.connect(engine)
        with self.assertRaises(TestbenchError):
            engine.submit({"action": "setup", "params": {"ssid": "test", "password": "short"}})
        self.assertEqual(client.provisions, 0)
        self.assertFalse(engine.recovery_required)

    def test_full_cannot_silently_skip_wifi_or_uart(self):
        engine = self.engine()
        engine.submit({"action": "test", "params": {"profile": "full", "confirm_configuration": True}})
        self.assertEqual(wait_job(engine)["error"]["code"], "TB_UART_REQUIRED")
        self.assertFalse(engine.fake_clients)
        engine.uart_port = "fake-uart"
        engine.submit({"action": "test", "params": {"profile": "full", "confirm_configuration": True}})
        self.assertEqual(wait_job(engine)["error"]["code"], "TB_WIFI_CREDENTIALS_REQUIRED")
        self.assertFalse(engine.fake_clients)

    def test_linux_report_never_claims_android_or_sensor(self):
        engine = self.engine()
        self.connect(engine)
        report = engine.report()
        self.assertFalse(report["android_verified"])
        self.assertFalse(report["sensor_verified"])
        self.assertEqual(report["verifications"]["android"], "pending")
        self.assertEqual(report["mobile_contract_platform"], "linux")

    def test_missing_ip_mobile_flow_aborts_before_provisioning(self):
        engine = self.engine()
        engine.submit({"action": "test", "params": {"profile": "mobile-flow", "ssid": "test-network", "password": "test-password"}})
        self.assertEqual(wait_job(engine)["error"]["code"], "TB_MANUAL_IP_REQUIRED")
        self.assertFalse(engine.fake_clients)

    def test_cancel_after_provision_write_does_not_reboot_or_resend(self):
        engine = self.engine()
        client = self.connect(engine)
        original = client.wifi_config_put

        def cancelled_write(ssid, password):
            result = original(ssid, password)
            engine.cancelled.set()
            return result

        client.wifi_config_put = cancelled_write
        engine.submit({"action": "setup", "params": {"ssid": "test-network", "password": "test-password"}})
        self.assertEqual(wait_job(engine)["status"], "cancelled")
        self.assertEqual(client.provisions, 1)
        self.assertNotIn(WIRE.CMD_REBOOT, client.commands)
        self.assertTrue(engine.report()["configuration_may_require_recovery"])

    def test_fresh_uart_reset_gates_attach_until_wifi_and_listener(self):
        engine = self.engine()
        boot = ("rst:0x1 (POWERON_RESET)\noperation=boot.mode mode=wifi_only ble=0\n"
                "operation=boot.ready camera=1\n")
        ready = "operation=wifi.got_ip ip=192.168.1.100 outcome=success\nUDP socket bound on port 8888\n"

        class FakeUART:
            def __init__(self):
                self.capture = boot
                self.calls = 0

            def poll(self):
                return

            def text(self, since=0):
                return self.capture

            def mark(self):
                return len(self.capture)

            def wait_for(self, predicate, since, timeout, code, pump):
                self.calls += 1
                self.assert_not_ready = predicate(self.capture)
                self.capture += ready
                return predicate(self.capture)

        uart = FakeUART()
        engine.uart = uart
        engine.owner = threading.get_ident()
        engine.uart_open_pending = True
        engine._await_uart_wifi("192.168.1.100")
        self.assertEqual(uart.calls, 1)
        self.assertIsNone(uart.assert_not_ready)
        self.assertFalse(engine.uart_open_pending)
        engine.uart = None

    def test_fresh_uart_ble_mode_and_ip_mismatch_rejected(self):
        engine = self.engine()
        engine.owner = threading.get_ident()

        class FakeUART:
            def __init__(self, text):
                self.capture = text

            def poll(self):
                return

            def text(self, since=0):
                return self.capture

            def wait_for(self, predicate, *args):
                return predicate(self.capture)

        for text, expected in (("operation=boot.mode mode=ble_setup ble=1\n", "TB_FRESH_BLE_SETUP_REQUIRED"),
                               ("operation=boot.mode mode=wifi_only ble=0\noperation=boot.ready camera=1\n"
                                "operation=wifi.got_ip ip=192.168.1.101\nUDP socket bound on port 8888\n", "TB_UART_IP_MISMATCH")):
            engine.uart = FakeUART(text)
            with self.assertRaises(TestbenchError) as caught:
                engine._await_uart_wifi("192.168.1.100")
            self.assertEqual(caught.exception.code, expected)
        engine.uart = None

    def test_output_is_sanitized_no_raw_uart_or_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = self.engine(output=directory)
            client = self.connect(engine)
            client.fail_provision = True
            engine.submit({"action": "setup", "params": {"ssid": "private-network", "password": "private-password"}})
            wait_job(engine)
            engine.close()
            output = Path(directory) / "results.json"
            self.assertTrue(output.exists())
            body = output.read_text()
            self.assertNotIn("private-network", body)
            self.assertNotIn("private-password", body)
            self.assertFalse((Path(directory) / "uart.log").exists())

    def test_disconnect_cleanup_failure_is_failed_and_attempts_all_resources(self):
        engine = self.engine()
        client = self.connect(engine)
        original = client.command

        def fail_pause(command, ack=None):
            original(command, ack)
            if command == WIRE.CMD_STREAM_OFF:
                raise TimeoutError("HIL_CLEANUP_REPLY_TIMEOUT")

        client.command = fail_pause
        engine.uart = SimpleNamespace(
            poll=lambda: None,
            __exit__=Mock(side_effect=RuntimeError("HIL_UART_CLEANUP_INCOMPLETE")))
        uart = engine.uart
        engine.verifications.update(firmware=True, mobile_contract=True)
        engine.submit({"action": "disconnect"})
        job = wait_job(engine)
        self.assertEqual(job["status"], "failed")
        self.assertEqual(job["error"]["code"], "TB_CLEANUP_INCOMPLETE")
        self.assertEqual(client.commands, [WIRE.CMD_STREAM_OFF, WIRE.CMD_FLASH_OFF])
        self.assertFalse(client.connected)
        uart.__exit__.assert_called_once()
        self.assertFalse(FakeLock.held)
        self.assertFalse(engine.report()["ok"])
        self.assertFalse(engine.report()["verifications"]["firmware"])

    def test_shutdown_cleanup_failure_invalidates_pass_and_saved_report(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = self.engine(output=directory)
            client = self.connect(engine)
            client.disconnect = Mock(side_effect=OSError("private cleanup detail"))
            engine.verifications.update(firmware=True, mobile_contract=True)
            engine.close()
            report = engine.report()
            self.assertFalse(report["ok"])
            self.assertEqual(report["error"]["code"], "TB_CLEANUP_INCOMPLETE")
            self.assertEqual(report["job"]["status"], "failed")
            self.assertFalse(report["verifications"]["firmware"])
            self.assertFalse(report["verifications"]["mobile_contract"])
            saved = json.loads((Path(directory) / "results.json").read_text())
            self.assertFalse(saved["ok"])
            self.assertNotIn("private cleanup detail", json.dumps(saved))
            self.assertFalse(FakeLock.held)

    def test_shutdown_during_idle_cooperation_is_not_an_operation_failure(self):
        engine = self.engine()
        self.connect(engine)
        entered = threading.Event()

        def idle_until_shutdown():
            entered.set()
            if not engine.stop.wait(1):
                raise AssertionError("shutdown was not requested")
            engine.cooperate()

        engine._idle_pump = idle_until_shutdown
        self.assertTrue(entered.wait(1))
        engine.close()
        report = engine.report()
        self.assertTrue(report["ok"])
        self.assertIsNone(report["error"])
        self.assertFalse(FakeLock.held)

    def test_cleanup_failure_does_not_mask_original_job_failure(self):
        engine = self.engine()
        client = self.connect(engine)
        client.wifi_config_put = Mock(side_effect=TimeoutError("HIL_ORIGINAL_FAILURE"))
        client.disconnect = Mock(side_effect=OSError("private cleanup detail"))
        engine.submit({"action": "setup", "params": {"ssid": "test-network", "password": "test-password"}})
        job = wait_job(engine)
        self.assertEqual(job["status"], "failed")
        self.assertEqual(job["error"]["code"], "HIL_ORIGINAL_FAILURE")
        self.assertEqual(engine.report()["error"]["code"], "HIL_ORIGINAL_FAILURE")
        self.assertTrue(any(event.get("code") == "TB_CLEANUP_INCOMPLETE" for event in engine.report()["events"]))
        self.assertFalse(FakeLock.held)


class ActualSetupCancellationTests(unittest.TestCase):
    def setUp(self):
        self.engine = HardwareEngine()
        self.engine.owner = threading.get_ident()
        self.addCleanup(self.engine.close)
        self.params = {"ssid": FIXTURE_SSID, "password": FIXTURE_PASSWORD}

    def assert_cancelled(self, function):
        with self.assertRaises(TestbenchError) as caught:
            function()
        self.assertEqual(caught.exception.code, "TB_CANCELLED")

    def test_nm_retrieval_cancellation_never_reaches_actual_credential_write(self):
        def retrieve():
            self.engine.cancelled.set()
            return FIXTURE_SSID, FIXTURE_PASSWORD

        with actual_bluez(self.engine) as fixture, \
                patch("testbench.engine.suites", return_value=(
                    SimpleNamespace(network_manager_credentials=retrieve), None)):
            self.assert_cancelled(lambda: self.engine._setup({"wifi_from_nm": True}, reboot=False))
            self.assertEqual(fixture.writes, [])
            self.assertFalse(self.engine.recovery_required)

    def test_cancel_at_real_write_boundary_prevents_payload_and_retains_guard(self):
        with actual_bluez(self.engine) as fixture:
            original = fixture.client.write

            def cancel(data):
                self.engine.cancelled.set()
                return original(data)

            with patch.object(fixture.client, "write", side_effect=cancel):
                self.assert_cancelled(lambda: self.engine._setup(self.params))
            self.assertEqual(fixture.writes, [])
            self.assertTrue(self.engine.recovery_required)

    def test_inflight_cancel_retains_uncertainty_despite_late_actual_ack(self):
        with actual_bluez(self.engine) as fixture:
            fixture.during_write = lambda _: self.engine.cancelled.set()
            self.assert_cancelled(lambda: self.engine._setup(self.params))
            self.assertEqual([entry["code"] for entry in fixture.writes], [WIRE.CMD_WIFI_CONFIG_PUT])
            self.assertTrue(fixture.writes[0]["uncertain"])
            self.engine.cleaning = True
            fixture.client.pump()
            self.engine.cleaning = False
            self.assertTrue(any(line == "$CMD:wifi_config_received" for _, line in fixture.client.lines))
            self.assertTrue(self.engine.recovery_required)
            self.engine._cleanup()
            self.assertEqual([entry["code"] for entry in fixture.writes],
                             [WIRE.CMD_WIFI_CONFIG_PUT, WIRE.CMD_STREAM_OFF, WIRE.CMD_FLASH_OFF])

    def test_postwrite_cancellation_prevents_provisioned_state_and_reboot(self):
        with actual_bluez(self.engine) as fixture:
            original = fixture.client.wifi_config_put

            def cancel_after_ack(*args):
                result = original(*args)
                self.engine.cancelled.set()
                return result

            with patch.object(fixture.client, "wifi_config_put", side_effect=cancel_after_ack):
                self.assert_cancelled(lambda: self.engine._setup(self.params))
            self.assertEqual(self.engine.snapshot()["phase"], "paired")
            self.assertTrue(self.engine.recovery_required)
            self.assertEqual([entry["code"] for entry in fixture.writes], [WIRE.CMD_WIFI_CONFIG_PUT])

    def test_cancel_with_late_identity_reply_cannot_complete_nonreboot_setup(self):
        with actual_bluez(self.engine) as fixture:
            original = fixture.client.line

            def cancel_after_identity(prefix, *args, **kwargs):
                result = original(prefix, *args, **kwargs)
                if prefix == "$ESP_NAME:":
                    self.engine.cancelled.set()
                return result

            with patch.object(fixture.client, "line", side_effect=cancel_after_identity):
                self.assert_cancelled(lambda: self.engine._setup(self.params, reboot=False))
            self.assertEqual(self.engine.snapshot()["phase"], "paired")
            self.assertTrue(self.engine.recovery_required)
            self.assertEqual([entry["code"] for entry in fixture.writes], [WIRE.CMD_WIFI_CONFIG_PUT])

    def test_late_actual_udp_frame_after_cancel_cannot_clear_configuration_guard(self):
        self.engine.lock_factory = FakeLock
        self.engine.decoder = lambda _: (320, 240)
        self.engine.recovery_required = True
        ip = "192.0.2.10"
        packet = WIRE.UDP_HEADER.pack(0, 1, 0, len(FAKE_JPEG), 1, len(FAKE_JPEG)) + FAKE_JPEG
        socket = Mock(spec=["bind", "setsockopt", "setblocking", "sendto", "recvfrom", "close"])
        socket.recvfrom.side_effect = [
            (b"$CMD:keepalive\n", (ip, WIRE.UDP_PORT)),
            (packet, (ip, WIRE.UDP_PORT)),
            BlockingIOError(),
        ]
        original = UdpReceiver.next_frame

        def late_frame(receiver, *args, **kwargs):
            result = original(receiver, *args, **kwargs)
            self.engine.cancelled.set()
            return result

        with patch.object(WIRE.socket, "socket", return_value=socket), \
                patch.object(UdpReceiver, "next_frame", late_frame):
            try:
                self.assert_cancelled(lambda: self.engine._attach(ip))
                self.assertTrue(self.engine.recovery_required)
                self.assertNotEqual(self.engine.snapshot()["phase"], "wifi_ready")
            finally:
                self.engine._cleanup()
        self.assertEqual([call.args[0][0] for call in socket.sendto.call_args_list],
                         [WIRE.CMD_UDP_KEEPALIVE, WIRE.CMD_SINGLE_FRAME,
                          WIRE.CMD_STREAM_OFF, WIRE.CMD_FLASH_OFF])
        socket.close.assert_called_once()
        self.assertFalse(FakeLock.held)


class FinalRunHealthTests(unittest.TestCase):
    def tearDown(self):
        self.assertFalse(FakeLock.held)

    def receive_failure(self, directory, *, cleanup_failure=False, previous_error=None):
        engine = fake_engine(output=directory)
        self.addCleanup(engine.close)
        initial_saved, failed_saved, released = threading.Event(), threading.Event(), threading.Event()
        inject = threading.Event()
        original_save, original_execute = engine._save_report, engine._execute
        original_factory = engine.client_factory
        failures = []

        def execute(*args):
            original_execute(*args)
            with engine.lock:
                # Synthetic prior verification flags, not a hardware claim.
                engine.verifications.update(firmware=True, mobile_contract=True)

        def factory(*args):
            client = original_factory(*args)
            original_pump, original_disconnect = client.pump, client.disconnect

            def pump(*args):
                if inject.is_set():
                    raise TestbenchError("TB_IDLE_RECEIVE_FAILURE")
                return original_pump(*args)

            def disconnect():
                self.assertTrue(FakeLock.held)
                original_disconnect()
                released.set()
                if cleanup_failure:
                    raise OSError("private receive cleanup detail")

            client.pump, client.disconnect = pump, disconnect
            return client

        def save():
            original_save()
            report = engine.report()
            if any(event["operation"] == "receive" and event["outcome"] == "failure"
                   for event in report["events"]):
                failures.append(report)
                failed_saved.set()
            else:
                initial_saved.set()

        engine._execute, engine.client_factory, engine._save_report = execute, factory, save
        engine.submit({"action": "connect"})
        self.assertEqual(wait_job(engine)["status"], "passed")
        self.assertTrue(initial_saved.wait(WAIT_SECONDS))
        initial = json.loads((Path(directory) / "results.json").read_text())
        self.assertTrue(initial["ok"])
        if previous_error is not None:
            engine._update(error=previous_error)
        inject.set()
        self.assertTrue(released.wait(WAIT_SECONDS))
        persisted_before_close = failed_saved.wait(WAIT_SECONDS)
        engine.close()
        self.assertTrue(persisted_before_close, "Idle receive failure was not persisted after cleanup")
        self.assertTrue(failures)
        return engine.report(), json.loads((Path(directory) / "results.json").read_text())

    def test_idle_receive_failure_invalidates_live_and_saved_run_after_successful_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            live, saved = self.receive_failure(directory)
        for report in (live, saved):
            self.assertFalse(report["ok"])
            self.assertEqual(report["job"]["status"], "passed")
            self.assertEqual(report["error"]["code"], "TB_IDLE_RECEIVE_FAILURE")
            self.assertFalse(report["verifications"]["firmware"])
            self.assertFalse(report["verifications"]["mobile_contract"])
            self.assertFalse(any(event["operation"] == "cleanup" and event["outcome"] == "failure"
                                 for event in report["events"]))
        self.assertEqual(live["events"], saved["events"])

    def test_idle_receive_and_cleanup_failure_keep_primary_error_and_historical_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            live, saved = self.receive_failure(directory, cleanup_failure=True)
        for report in (live, saved):
            self.assertFalse(report["ok"])
            self.assertEqual(report["error"]["code"], "TB_IDLE_RECEIVE_FAILURE")
            self.assertEqual(report["job"]["status"], "passed")
            self.assertFalse(report["verifications"]["firmware"])
            self.assertFalse(report["verifications"]["mobile_contract"])
            self.assertTrue(any(event.get("code") == "TB_CLEANUP_INCOMPLETE" for event in report["events"]))
            self.assertNotIn("private receive cleanup detail", json.dumps(report))

    def test_idle_receive_does_not_overwrite_existing_run_error(self):
        previous = TestbenchError("TB_ORIGINAL_RUN_FAILURE").public()
        with tempfile.TemporaryDirectory() as directory:
            live, saved = self.receive_failure(directory, cleanup_failure=True, previous_error=previous)
        for report in (live, saved):
            self.assertEqual(report["error"], previous)
            self.assertFalse(report["ok"])
            self.assertTrue(any(event.get("code") == "TB_IDLE_RECEIVE_FAILURE" for event in report["events"]))

    def test_successful_shutdown_persists_after_resources_are_released(self):
        with tempfile.TemporaryDirectory() as directory:
            engine = fake_engine(output=directory)
            self.addCleanup(engine.close)
            original_save = engine._save_report
            saves = []

            def save():
                saves.append({"held": bool(FakeLock.held), "client": engine.client is not None})
                original_save()

            engine._save_report = save
            engine.submit({"action": "connect"})
            self.assertEqual(wait_job(engine)["status"], "passed")
            engine.close()
            self.assertGreaterEqual(len(saves), 2)
            self.assertEqual(saves[-1], {"held": False, "client": False})
            saved = json.loads((Path(directory) / "results.json").read_text())
            self.assertTrue(saved["ok"])
            self.assertIsNone(saved["error"])
            self.assertEqual(saved["events"], engine.report()["events"])

    def test_metrics_failure_cannot_skip_independent_teardown_or_release_early(self):
        engine = HardwareEngine(lock_factory=FakeLock)
        engine.owner = threading.get_ident()
        engine._acquire()
        calls = []
        original_release = engine.hardware_lock.release

        def release():
            self.assertEqual(calls, ["udp.pause", "udp.flash", "udp.close", "uart.close"])
            self.assertIsNone(engine.client)
            original_release()

        engine.hardware_lock.release = release
        self.addCleanup(original_release)
        self.addCleanup(engine._cleanup)

        def command(data):
            self.assertTrue(FakeLock.held)
            calls.append("udp.pause" if data[0] == WIRE.CMD_STREAM_OFF else "udp.flash")
            if data[0] == WIRE.CMD_STREAM_OFF:
                raise TimeoutError("HIL_PAUSE_FAILURE")

        def close_udp():
            self.assertTrue(FakeLock.held)
            calls.append("udp.close")
            raise OSError("private UDP close detail")

        def close_uart(*_):
            self.assertTrue(FakeLock.held)
            calls.append("uart.close")
            raise OSError("private UART close detail")

        engine.udp = SimpleNamespace(command=command, close=close_udp)
        engine.uart = SimpleNamespace(poll=lambda: None, __exit__=close_uart)
        primary = TestbenchError("TB_ORIGINAL_RECEIVE_FAILURE").public()
        engine._update(error=primary)
        with actual_bluez(engine) as fixture, \
                patch.object(engine, "_udp_metrics", side_effect=OSError("private metrics detail")):
            failures = engine._cleanup()
            self.assertEqual([entry["code"] for entry in fixture.writes],
                             [WIRE.CMD_STREAM_OFF, WIRE.CMD_FLASH_OFF])
        self.assertEqual(len(failures), 4)
        self.assertEqual(engine.report()["error"], primary)
        self.assertFalse(engine.cleaning)
        self.assertFalse(FakeLock.held)
        self.assertIsNone(engine.udp)
        self.assertIsNone(engine.uart)


if __name__ == "__main__":
    unittest.main()
