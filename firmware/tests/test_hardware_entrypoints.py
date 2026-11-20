"""Standalone ownership regressions using fake hardware and temporary lock files."""

import contextlib
import io
import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock, patch

import boot_smoke
import hardware_e2e
import wifi_retry_hil
import hardware_helpers
from standalone_signals import StandaloneSignals, StandaloneInterrupted
from testbench.errors import TestbenchError
from testbench.hardware_lock import HardwareLock
from testbench.settings import DEFAULT_ADAPTER


ENTRYPOINTS = (hardware_e2e, wifi_retry_hil, boot_smoke)
SUITE_ENTRYPOINTS = (hardware_e2e, wifi_retry_hil)
FIXTURE_ADAPTER = "hci-entrypoint-fixture"
FIXTURE_VERSION = "entrypoint-fixture"
BOOT_DATA = (
    "rst:0x1 (POWERON_RESET)\n"
    "operation=boot.mode mode=ble_setup ble=1\n"
    "operation=boot.ready camera=1 sensor=0 psram=8388608 "
    f"version={FIXTURE_VERSION}\n"
    "operation=camera.boot_capture jpeg=valid\n"
    "operation=ble.advertise\n"
).encode()
NATIVE_SIGNAL = signal.signal
NATIVE_GETSIGNAL = signal.getsignal


class EntryPointProbe:
    """Assert ownership at every fake constructor, operation and cleanup callback."""

    def __init__(self, test, module, directory, failures=None, real_suite=False):
        self.test, self.module, self.directory = test, module, directory
        self.failures = failures or {}
        self.real_suite = real_suite
        self.record_cases = False
        self.real_provision = False
        self.case_operations = {}
        self.on_event = {}
        self.wifi = None
        self.udp_suite = False
        self.events = []
        self.held = self.uart_open = False
        self.disconnects = 0
        self.port = str(directory / "uart-fixture")
        self.adapter = FIXTURE_ADAPTER
        self.output = directory / ("boot.bin" if module is boot_smoke else "evidence")
        self.lock_factory = Mock(side_effect=self.make_lock)
        self.client_factory = Mock(side_effect=self.make_client)
        self.uart_factory = Mock(side_effect=self.make_uart)
        self.suite_factory = Mock(side_effect=self.make_suite)
        self.serial_factory = Mock(side_effect=self.make_serial)
        self.credentials = Mock(side_effect=self.read_credentials)

    def event(self, name):
        self.test.assertTrue(self.held, f"{name} ran without ownership")
        self.events.append(name)
        if name in self.on_event:
            self.on_event[name]()
        if name in self.failures:
            raise self.failures[name]

    def make_lock(self, adapter, port):
        self.test.assertFalse(self.held)
        self.test.assertEqual((adapter, port), (self.adapter, self.port))
        probe = self

        class Lease:
            def __enter__(self):
                probe.events.append("lock.acquire")
                if "lock.acquire" in probe.failures:
                    raise probe.failures["lock.acquire"]
                probe.held = True
                if "lock.acquire" in probe.on_event:
                    probe.on_event["lock.acquire"]()
                return self

            def __exit__(self, *_):
                probe.test.assertFalse(probe.uart_open, "UART still open at release")
                probe.event("lock.release")
                probe.held = False

        return Lease()

    def read_credentials(self, interruption=None):
        self.event("credentials.read")
        return self.wifi

    def make_client(self, adapter):
        self.test.assertEqual(adapter, self.adapter)
        self.event("client.construct")

        def disconnect():
            self.disconnects += 1
            self.event(f"client.disconnect.{self.disconnects}")
            self.event(f"client.disconnected.{self.disconnects}")

        def wait(predicate, *_):
            self.event("client.wait")
            self.test.assertTrue(predicate())

        def wifi_config_put(ssid, password):
            self.event("client.wifi_config_put")
            self.suite.fixture_ssid = ssid
            return len(ssid.encode()) + len(password.encode()) + 3

        return SimpleNamespace(
            rx=object(), device_path="/fixture/device",
            manager=SimpleNamespace(GetManagedObjects=lambda: {}),
            pair=lambda: self.event("client.pair"),
            reboot=lambda: self.event("client.reboot"), wait=wait,
            disconnect=disconnect,
            command=lambda command, reply: self.event(f"media.command.{command}"),
            wifi_config_put=wifi_config_put,
            wifi_erase=lambda: self.event("client.wifi_erase"),
        )

    def make_uart(self, port, output):
        self.test.assertEqual((port, output), (self.port, self.output / "uart.log"))
        self.event("uart.construct")
        probe = self

        class UART:
            error = None

            def __init__(self):
                self.cleanup_errors = []

            def __enter__(self):
                probe.event("uart.enter")
                probe.uart_open = True
                return self

            def __exit__(self, exc_type, *_):
                try:
                    probe.event("uart.exit")
                except Exception as error:
                    self.cleanup_errors.append(type(error).__name__)
                    if exc_type is None:
                        raise
                finally:
                    probe.uart_open = False
                    probe.event("uart.closed")

            def reset(self):
                probe.event("uart.reset")
                return 0

            def mark(self):
                probe.event("uart.mark")
                return 0

            def wait(self, *args, **kwargs):
                probe.event("uart.wait")

        return UART()

    def make_suite(self, client, output, wifi):
        self.event("suite.construct")
        suite = self.make_suite_class(client, output, wifi)
        self.suite = suite
        original_case = suite.case

        def run():
            try:
                self.event("suite.run")
            finally:
                self.event("suite.media_cleanup")
                self.event("suite.media_closed")

        def provision(ssid, password):
            self.event("suite.provision")
            suite.fixture_ssid = ssid

        def case(name, function):
            def operation():
                self.event("case." + name)
                return self.case_operations.get(name, lambda: {"fixture": True})()
            return original_case(name, operation) if self.record_cases else operation()

        if self.real_suite:
            suite.case = case
            if self.udp_suite:
                self.event("udp.construct")
                suite.phase = "wifi"
                suite.udp = SimpleNamespace(closed=False)

                def close_udp():
                    self.event("udp.close")
                    suite.udp.closed = True
                    self.event("udp.closed")

                suite.udp.close = close_udp
                suite.udp_control = lambda command: self.event(f"udp.control.{command}")
        else:
            suite.run = run
        suite.advertisement_and_gatt = lambda: self.event("suite.advertisement") or {"fixture": True}
        if not self.real_provision:
            suite.provision = provision
        suite.wifi_config_get = lambda: self.event("suite.config_get") or suite.fixture_ssid
        suite.status = lambda: self.event("suite.status") or {"wifi": "disconnected"}
        return suite

    def make_serial(self, port, baudrate, timeout):
        self.test.assertIsNone(port)
        self.event("serial.construct")
        probe = self

        class Serial:
            is_open = False
            in_waiting = 1

            def __init__(self):
                self.counts = {"dtr": 0, "rts": 0}
                self.values = {"dtr": None, "rts": None}
                probe.serial = self

            @property
            def dtr(self):
                return self.values["dtr"]

            @dtr.setter
            def dtr(self, value):
                self.set_line("dtr", value)

            @property
            def rts(self):
                return self.values["rts"]

            @rts.setter
            def rts(self, value):
                self.set_line("rts", value)

            def set_line(self, name, value):
                self.counts[name] += 1
                probe.event(f"serial.{name}.{self.counts[name]}.{value}")
                self.values[name] = value

            def open(self):
                self.is_open = probe.uart_open = True
                probe.event("serial.open")

            def read(self, size):
                probe.event("serial.read")
                return BOOT_DATA

            def reset_input_buffer(self):
                probe.event("serial.reset_buffer")

            def close(self):
                try:
                    probe.closed_lines = dict(self.values)
                    probe.event("serial.close")
                finally:
                    self.is_open = probe.uart_open = False
                    probe.event("serial.closed")

        return Serial()

    def invoke(self, lock_factory=None, adapter=True):
        argv = [self.module.__file__, "--port", self.port, "--output", str(self.output)]
        if adapter:
            argv.extend(["--adapter", self.adapter])
        else:
            self.adapter = DEFAULT_ADAPTER
        if self.module is boot_smoke:
            argv.extend(["--version", FIXTURE_VERSION, "--seconds", "0.5", "--reset"])
        elif self.module is hardware_e2e:
            argv.append("--wifi-from-nm")
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch("sys.argv", argv))
            stack.enter_context(patch.dict(os.environ, {}, clear=True))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            stack.enter_context(patch.object(self.module, "HardwareLock", lock_factory or self.lock_factory))
            if self.module is boot_smoke:
                serial = ModuleType("serial")
                serial.Serial = self.serial_factory
                stack.enter_context(patch.dict(sys.modules, {"serial": serial}))
                stack.enter_context(patch.object(boot_smoke.time, "monotonic", side_effect=[0, 0.25, 0.75]))
                stack.enter_context(patch.object(boot_smoke.time, "sleep"))
            else:
                # Patch the constructor only in the entry point; use the real suite class inside the fake.
                suite_class = hardware_e2e.HardwareSuite
                stack.enter_context(patch.object(self.module, "BluezClient", self.client_factory))
                stack.enter_context(patch.object(self.module, "UARTLog", self.uart_factory))
                stack.enter_context(patch.object(self.module, "HardwareSuite", self.suite_factory))
                stack.enter_context(patch.object(hardware_e2e, "network_manager_credentials", self.credentials))
                self.make_suite_class = suite_class
                if self.module is wifi_retry_hil:
                    stack.enter_context(patch.object(wifi_retry_hil, "retry_settings", return_value=(2, 1)))
                    stack.enter_context(patch.object(wifi_retry_hil, "missing_ap_evidence",
                                                     side_effect=lambda *args: self.event("retry.evidence") or {"fixture": True}))
            result = self.module.main()
        if self.module is boot_smoke:
            report = json.loads(stderr.getvalue() if result else stdout.getvalue())
        else:
            report = json.loads((self.output / "results.json").read_text())
        self.test.assertFalse(self.held)
        return result, report


class HardwareEntryPointTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hil-entrypoints-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)

    def probe(self, module, failures=None, real_suite=False):
        return EntryPointProbe(self, module, self.directory, failures, real_suite)

    def test_lock_refusal_precedes_all_hardware_and_credentials(self):
        for module in ENTRYPOINTS:
            for code in ("TB_HARDWARE_LOCKED", "TB_HARDWARE_LOCK_UNSAFE", "TB_BLUEZ_REQUIRES_LINUX"):
                with self.subTest(entrypoint=module.__name__, code=code):
                    probe = self.probe(module, {"lock.acquire": TestbenchError(code)})
                    result, report = probe.invoke()
                    self.assertEqual(result, 1)
                    self.assertEqual(report["code"], code)
                    self.assertFalse(report["ok"])
                    self.assertEqual(probe.events, ["lock.acquire"])
                    for constructor in (probe.client_factory, probe.uart_factory, probe.suite_factory,
                                        probe.serial_factory, probe.credentials):
                        constructor.assert_not_called()

    def test_suite_success_closes_media_uart_and_client_before_release(self):
        for module in SUITE_ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module)
                result, report = probe.invoke()
                self.assertEqual(result, 0)
                self.assertTrue(report["ok"])
                self.assertEqual(probe.events[-4:], ["uart.closed", f"client.disconnect.{probe.disconnects}",
                                                     f"client.disconnected.{probe.disconnects}", "lock.release"])
                if module is hardware_e2e:
                    self.assertLess(probe.events.index("suite.media_closed"), probe.events.index("uart.exit"))
                probe.lock_factory.assert_called_once_with(probe.adapter, probe.port)

    def test_suite_failure_still_cleans_up_under_lock_and_keeps_code(self):
        for module, operation in ((hardware_e2e, "suite.run"), (wifi_retry_hil, "retry.evidence")):
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module, {operation: TimeoutError("HIL_OPERATION_TIMEOUT")})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_OPERATION_TIMEOUT")
                self.assertEqual(probe.events[-1], "lock.release")
                self.assertIn("uart.closed", probe.events)
                self.assertIn(f"client.disconnected.{probe.disconnects}", probe.events)

    def test_suite_construction_failure_disconnects_client_under_lock(self):
        for module in SUITE_ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module, {"suite.construct": RuntimeError("HIL_SUITE_CONSTRUCTION_FAILED")})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_SUITE_CONSTRUCTION_FAILED")
                probe.uart_factory.assert_not_called()
                self.assertEqual(probe.events[-3:], ["client.disconnect.1", "client.disconnected.1", "lock.release"])

    def test_client_construction_failure_releases_without_uart_or_suite(self):
        for module in SUITE_ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module, {"client.construct": RuntimeError("HIL_CLIENT_CONSTRUCTION_FAILED")})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_CLIENT_CONSTRUCTION_FAILED")
                probe.uart_factory.assert_not_called()
                probe.suite_factory.assert_not_called()
                self.assertEqual(probe.disconnects, 0)
                self.assertEqual(probe.events[-1], "lock.release")

    def test_uart_construction_or_entry_failure_disconnects_before_release(self):
        for module in SUITE_ENTRYPOINTS:
            for operation in ("uart.construct", "uart.enter"):
                with self.subTest(entrypoint=module.__name__, operation=operation):
                    probe = self.probe(module, {operation: RuntimeError("HIL_UART_OPEN_FAILED")})
                    result, report = probe.invoke()
                    self.assertEqual(result, 1)
                    self.assertEqual(report["code"], "HIL_UART_OPEN_FAILED")
                    self.assertNotIn("suite.run", probe.events)
                    self.assertNotIn("uart.exit", probe.events)
                    self.assertEqual(probe.events[-3:], ["client.disconnect.1", "client.disconnected.1", "lock.release"])

    def test_uart_cleanup_failure_still_disconnects_client_before_release(self):
        for module in SUITE_ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module, {"uart.exit": RuntimeError("HIL_UART_CLOSE_FAILED")})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_UART_CLOSE_FAILED")
                self.assertEqual(probe.events[-4:], ["uart.closed", f"client.disconnect.{probe.disconnects}",
                                                     f"client.disconnected.{probe.disconnects}", "lock.release"])

    def test_disconnect_failure_cannot_report_success(self):
        for module, count in ((hardware_e2e, 1), (wifi_retry_hil, 2)):
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module, {f"client.disconnect.{count}": OSError("private cleanup detail")})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertFalse(report["ok"])
                self.assertEqual(report["code"], "HIL_CLEANUP_INCOMPLETE")
                self.assertNotIn("private cleanup detail", json.dumps(report))
                self.assertEqual(probe.events[-2:], [f"client.disconnect.{count}", "lock.release"])

    def test_operation_failure_is_not_masked_by_final_disconnect_failure(self):
        for module, operation, count in ((hardware_e2e, "suite.run", 1), (wifi_retry_hil, "retry.evidence", 2)):
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module, {operation: TimeoutError("HIL_ORIGINAL_FAILURE"),
                                            f"client.disconnect.{count}": OSError("cleanup detail")})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_ORIGINAL_FAILURE")
                if module is hardware_e2e:
                    self.assertEqual(report["cleanup_errors"], ["OSError"])
                else:
                    self.assertEqual(report["cleanup_error_type"], "OSError")
                self.assertEqual(probe.events[-1], "lock.release")

    def test_cleanup_error_is_reported_even_without_constructed_suite(self):
        probe = self.probe(hardware_e2e, {"suite.construct": RuntimeError("HIL_SUITE_CONSTRUCTION_FAILED"),
                                           "client.disconnect.1": OSError("cleanup detail")})
        result, report = probe.invoke()
        self.assertEqual(result, 1)
        self.assertEqual(report["code"], "HIL_SUITE_CONSTRUCTION_FAILED")
        self.assertEqual(report["cleanup_errors"], ["OSError"])

    def test_uart_cleanup_details_survive_original_suite_failure(self):
        for module, operation in ((hardware_e2e, "suite.run"), (wifi_retry_hil, "retry.evidence")):
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module, {operation: TimeoutError("HIL_ORIGINAL_FAILURE"),
                                            "uart.exit": OSError("private UART cleanup detail")})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_ORIGINAL_FAILURE")
                key = "cleanup_errors" if module is hardware_e2e else "uart_cleanup_errors"
                self.assertEqual(report[key], ["OSError"])
                self.assertNotIn("private UART cleanup detail", json.dumps(report))
                self.assertEqual(probe.events[-1], "lock.release")

    def test_uart_cleanup_only_failure_includes_safe_details(self):
        for module in SUITE_ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module, {"uart.exit": RuntimeError("HIL_UART_CLEANUP_INCOMPLETE")})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertFalse(report["ok"])
                self.assertEqual(report["code"], "HIL_UART_CLEANUP_INCOMPLETE")
                key = "cleanup_errors" if module is hardware_e2e else "uart_cleanup_errors"
                self.assertEqual(report[key], ["RuntimeError"])

    def test_real_suite_cleanup_is_inside_single_entrypoint_lock(self):
        for failure in (False, True):
            with self.subTest(operation_failed=failure):
                failures = {"case.advertisement_and_gatt": TimeoutError("HIL_CASE_TIMEOUT")} if failure else None
                probe = self.probe(hardware_e2e, failures, real_suite=True)
                result, report = probe.invoke()
                self.assertEqual(result, int(failure))
                if failure:
                    self.assertEqual(report["code"], "HIL_CASE_TIMEOUT")
                for command in (hardware_e2e.CMD_STREAM_OFF, hardware_e2e.CMD_FLASH_OFF):
                    self.assertLess(probe.events.index(f"media.command.{command}"), probe.events.index("uart.exit"))
                probe.lock_factory.assert_called_once()

    def test_real_suite_udp_controls_and_socket_close_precede_uart_and_lock_release(self):
        probe = self.probe(hardware_e2e, real_suite=True)
        probe.udp_suite = True
        result, report = probe.invoke()
        self.assertEqual(result, 0)
        self.assertTrue(report["ok"])
        for command in (hardware_e2e.CMD_STREAM_OFF, hardware_e2e.CMD_FLASH_OFF):
            self.assertLess(probe.events.index(f"udp.control.{command}"), probe.events.index("udp.close"))
        self.assertLess(probe.events.index("udp.closed"), probe.events.index("uart.exit"))
        self.assertLess(probe.events.index("uart.closed"), probe.events.index("lock.release"))
        probe.lock_factory.assert_called_once()

    def test_real_suite_failed_first_ble_cleanup_still_turns_flash_off_and_disconnects(self):
        for operation_failed in (False, True):
            with self.subTest(operation_failed=operation_failed):
                failures = {"media.command.0": TimeoutError("private pause failure")}
                if operation_failed:
                    failures["case.advertisement_and_gatt"] = TimeoutError("HIL_ORIGINAL_FAILURE")
                probe = self.probe(hardware_e2e, failures, real_suite=True)
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertFalse(report["ok"])
                self.assertEqual(report["code"], "HIL_ORIGINAL_FAILURE" if operation_failed else "HIL_CLEANUP_INCOMPLETE")
                self.assertEqual(report["cleanup_errors"], ["TimeoutError"])
                expected = ["media.command.0", "media.command.4", "client.disconnect.1",
                            "client.disconnected.1", "uart.exit", "uart.closed",
                            "client.disconnect.2", "client.disconnected.2", "lock.release"]
                self.assertEqual(probe.events[-len(expected):], expected)
                self.assertNotIn("suite.provision", probe.events)
                self.assertNotIn("private pause failure", json.dumps(report))
                probe.lock_factory.assert_called_once()

    def test_real_suite_ble_cleanup_aggregates_failures_without_masking_primary_error(self):
        for operation_failed in (False, True):
            with self.subTest(operation_failed=operation_failed):
                failures = {"media.command.0": TimeoutError("private pause failure"),
                            "media.command.4": OSError("private flash failure"),
                            "client.disconnect.1": RuntimeError("private disconnect failure"),
                            "uart.exit": OSError("private UART failure"),
                            "client.disconnect.2": TimeoutError("private final disconnect failure")}
                if operation_failed:
                    failures["case.advertisement_and_gatt"] = TimeoutError("HIL_ORIGINAL_FAILURE")
                probe = self.probe(hardware_e2e, failures, real_suite=True)
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_ORIGINAL_FAILURE" if operation_failed else "HIL_CLEANUP_INCOMPLETE")
                self.assertEqual(report["cleanup_errors"], ["TimeoutError", "OSError", "RuntimeError",
                                                            "OSError", "TimeoutError"])
                for event in ("media.command.0", "media.command.4", "client.disconnect.1",
                              "uart.closed", "client.disconnect.2"):
                    self.assertLess(probe.events.index(event), probe.events.index("lock.release"))
                self.assertNotIn("private", json.dumps(report))

    def test_real_suite_failed_first_udp_cleanup_still_turns_flash_off_and_closes(self):
        for operation_failed in (False, True):
            with self.subTest(operation_failed=operation_failed):
                failures = {"udp.control.0": TimeoutError("private pause failure")}
                if operation_failed:
                    failures["case.udp_single_frame"] = TimeoutError("HIL_ORIGINAL_FAILURE")
                probe = self.probe(hardware_e2e, failures, real_suite=True)
                probe.udp_suite = True
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_ORIGINAL_FAILURE" if operation_failed else "HIL_CLEANUP_INCOMPLETE")
                self.assertEqual(report["cleanup_errors"], ["TimeoutError"])
                self.assertTrue(probe.suite.udp.closed)
                for event in ("udp.control.0", "udp.control.4", "client.disconnected.1", "udp.closed"):
                    self.assertLess(probe.events.index(event), probe.events.index("uart.exit"))
                self.assertEqual(probe.events[-1], "lock.release")
                self.assertNotIn("private pause failure", json.dumps(report))

    def test_real_suite_udp_close_failure_is_aggregated_after_all_teardown_attempts(self):
        for operation_failed in (False, True):
            with self.subTest(operation_failed=operation_failed):
                failures = {"udp.control.0": TimeoutError("private pause failure"),
                            "udp.control.4": OSError("private flash failure"),
                            "client.disconnect.1": RuntimeError("private disconnect failure"),
                            "udp.close": OSError("private socket failure")}
                if operation_failed:
                    failures["case.udp_single_frame"] = TimeoutError("HIL_ORIGINAL_FAILURE")
                probe = self.probe(hardware_e2e, failures, real_suite=True)
                probe.udp_suite = True
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_ORIGINAL_FAILURE" if operation_failed else "HIL_CLEANUP_INCOMPLETE")
                self.assertEqual(report["cleanup_errors"], ["TimeoutError", "OSError", "RuntimeError", "OSError"])
                for event in ("udp.control.0", "udp.control.4", "client.disconnect.1", "udp.close"):
                    self.assertLess(probe.events.index(event), probe.events.index("uart.exit"))
                self.assertIn("uart.closed", probe.events)
                self.assertIn("client.disconnected.2", probe.events)
                self.assertEqual(probe.events[-1], "lock.release")
                self.assertNotIn("private", json.dumps(report))

    def test_boot_capture_constructs_opens_resets_and_closes_under_lock(self):
        probe = self.probe(boot_smoke)
        result, report = probe.invoke()
        self.assertEqual(result, 0)
        self.assertTrue(report["ok"])
        self.assertEqual(probe.output.read_bytes(), BOOT_DATA)
        self.assertIn("serial.rts.2.True", probe.events)
        self.assertIn("serial.reset_buffer", probe.events)
        self.assertEqual(probe.events[-3:], ["serial.close", "serial.closed", "lock.release"])
        probe.lock_factory.assert_called_once_with(probe.adapter, probe.port)

    def test_boot_open_or_read_failure_closes_before_release(self):
        for operation in ("serial.open", "serial.read"):
            with self.subTest(operation=operation):
                probe = self.probe(boot_smoke, {operation: OSError("private UART detail")})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "BOOT_CAPTURE_FAILED")
                self.assertFalse(probe.output.exists())
                self.assertEqual(probe.events[-3:], ["serial.close", "serial.closed", "lock.release"])

    def test_boot_constructor_failure_does_not_open_uart(self):
        probe = self.probe(boot_smoke, {"serial.construct": OSError("UART unavailable")})
        result, report = probe.invoke()
        self.assertEqual(result, 1)
        self.assertEqual(report["code"], "BOOT_CAPTURE_FAILED")
        self.assertEqual(probe.events, ["lock.acquire", "serial.construct", "lock.release"])

    def test_boot_line_cleanup_failure_still_closes_under_lock(self):
        for line in ("serial.dtr.2.False", "serial.rts.4.False"):
            with self.subTest(line=line):
                probe = self.probe(boot_smoke, {line: OSError("line control failed")})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "BOOT_CAPTURE_FAILED")
                self.assertEqual(report["cleanup_errors"], ["OSError"])
                self.assertLess(probe.events.index("serial.dtr.2.False"), probe.events.index("serial.rts.4.False"))
                self.assertLess(probe.events.index("serial.rts.4.False"), probe.events.index("serial.close"))
                self.assertEqual(probe.events[-3:], ["serial.close", "serial.closed", "lock.release"])

    def test_boot_cleanup_only_failure_aggregates_both_lines_and_close(self):
        probe = self.probe(boot_smoke, {
            "serial.dtr.2.False": OSError("private DTR failure"),
            "serial.rts.4.False": RuntimeError("private RTS failure"),
            "serial.close": OSError("private close failure"),
        })
        result, report = probe.invoke()
        self.assertEqual(result, 1)
        self.assertFalse(report["ok"])
        self.assertEqual(report["code"], "BOOT_CAPTURE_FAILED")
        self.assertEqual(report["cleanup_errors"], ["OSError", "RuntimeError", "OSError"])
        self.assertEqual(probe.events[-5:], ["serial.dtr.2.False", "serial.rts.4.False",
                                            "serial.close", "serial.closed", "lock.release"])
        self.assertFalse(probe.output.exists())
        self.assertNotIn("private", json.dumps(report))

    def test_boot_primary_failure_survives_dtr_cleanup_and_rts_is_deasserted_before_close(self):
        primary = TestbenchError("TB_BOOT_OPERATION_FAILED")
        probe = self.probe(boot_smoke, {
            "serial.reset_buffer": primary,
            "serial.dtr.2.False": OSError("private DTR failure"),
        })
        result, report = probe.invoke()
        self.assertEqual(result, 1)
        self.assertEqual(report["code"], primary.code)
        self.assertEqual(report["type"], "TestbenchError")
        self.assertEqual(report["cleanup_errors"], ["OSError"])
        self.assertEqual(primary.cleanup_errors, ["OSError"])
        self.assertEqual(probe.closed_lines["rts"], False)
        self.assertEqual(probe.events[-5:], ["serial.dtr.2.False", "serial.rts.3.False",
                                            "serial.close", "serial.closed", "lock.release"])
        self.assertFalse(probe.output.exists())

    def test_boot_primary_failure_survives_all_cleanup_failures(self):
        primary = TestbenchError("TB_BOOT_OPERATION_FAILED")
        probe = self.probe(boot_smoke, {
            "serial.reset_buffer": primary,
            "serial.dtr.2.False": OSError("private DTR failure"),
            "serial.rts.3.False": RuntimeError("private RTS failure"),
            "serial.close": OSError("private close failure"),
        })
        result, report = probe.invoke()
        self.assertEqual(result, 1)
        self.assertEqual(report["code"], primary.code)
        self.assertEqual(report["type"], "TestbenchError")
        self.assertEqual(report["cleanup_errors"], ["OSError", "RuntimeError", "OSError"])
        self.assertEqual(probe.events[-5:], ["serial.dtr.2.False", "serial.rts.3.False",
                                            "serial.close", "serial.closed", "lock.release"])
        self.assertFalse(probe.output.exists())
        self.assertNotIn("private", json.dumps(report))

    def test_boot_partial_initialization_still_resets_both_lines_and_closes(self):
        for operation in ("serial.dtr.1.False", "serial.rts.1.False"):
            with self.subTest(operation=operation):
                primary = TestbenchError("TB_BOOT_OPERATION_FAILED")
                probe = self.probe(boot_smoke, {operation: primary})
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], primary.code)
                self.assertEqual(report["cleanup_errors"], [])
                self.assertEqual(probe.closed_lines, {"dtr": False, "rts": False})
                self.assertNotIn("serial.open", probe.events)
                self.assertEqual(probe.events[-3:], ["serial.close", "serial.closed", "lock.release"])

    def test_boot_close_failure_is_reported_without_success(self):
        probe = self.probe(boot_smoke, {"serial.close": OSError("close failed")})
        result, report = probe.invoke()
        self.assertEqual(result, 1)
        self.assertFalse(report["ok"])
        self.assertEqual(report["code"], "BOOT_CAPTURE_FAILED")
        self.assertEqual(probe.events[-3:], ["serial.close", "serial.closed", "lock.release"])

    def test_all_entrypoints_share_default_adapter(self):
        for module in ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module)
                result, _ = probe.invoke(adapter=False)
                self.assertEqual(result, 0)
                probe.lock_factory.assert_called_once_with(DEFAULT_ADAPTER, probe.port)

    @unittest.skipUnless(sys.platform == "linux", "Linux flock contract")
    def test_actual_adapter_contention_refuses_all_standalone_entrypoints(self):
        for module in ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module)
                directory = self.directory / "locks"
                with HardwareLock(probe.adapter, directory=directory):
                    result, report = probe.invoke(lock_factory=lambda adapter, port: HardwareLock(adapter, port, directory))
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "TB_HARDWARE_LOCKED")
                probe.client_factory.assert_not_called()
                probe.uart_factory.assert_not_called()
                probe.serial_factory.assert_not_called()
                with HardwareLock(probe.adapter, probe.port, directory):
                    pass

    @unittest.skipUnless(sys.platform == "linux", "Linux flock contract")
    def test_actual_canonical_uart_contention_refuses_and_rolls_back_adapter(self):
        alias = self.directory / "uart-alias"
        alias.symlink_to(self.directory / "uart-fixture")
        directory = self.directory / "locks"
        for module in ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module)
                with HardwareLock("hci-other-fixture", str(alias), directory):
                    result, report = probe.invoke(lock_factory=lambda adapter, port: HardwareLock(adapter, port, directory))
                    with HardwareLock(probe.adapter, directory=directory):
                        pass
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "TB_HARDWARE_LOCKED")
                probe.client_factory.assert_not_called()
                probe.uart_factory.assert_not_called()
                probe.serial_factory.assert_not_called()

    def test_standalone_imports_and_help_work_outside_repository(self):
        environment = {**os.environ, "PYTHONPATH": "", "PYTHONDONTWRITEBYTECODE": "1"}
        for module in ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                result = subprocess.run([sys.executable, str(Path(module.__file__).resolve()), "--help"],
                                        cwd=self.directory, env=environment, capture_output=True,
                                        text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("--adapter", result.stdout)
                self.assertNotIn("Traceback", result.stderr)


class SignalRegistry:
    """Deterministic handlers, with no signals sent to unrelated processes."""

    def __init__(self):
        self.previous = {signum: object() for signum in (signal.SIGINT, signal.SIGTERM)}
        self.handlers = dict(self.previous)
        self.calls = []

    def install(self, signum, handler):
        self.calls.append((signum, handler))
        self.handlers[signum] = handler

    def send(self, signum):
        self.handlers[signum](signum, None)


class StandaloneSignalTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="hil-signal-fixture-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.registry = SignalRegistry()
        stack = contextlib.ExitStack()
        self.addCleanup(stack.close)
        stack.enter_context(patch("standalone_signals.signal.getsignal", side_effect=self.registry.handlers.__getitem__))
        stack.enter_context(patch("standalone_signals.signal.signal", side_effect=self.registry.install))

    def probe(self, module, **kwargs):
        return EntryPointProbe(self, module, self.directory, **kwargs)

    def assert_restored(self):
        self.assertEqual(self.registry.handlers, self.registry.previous)

    def test_signal_during_suite_operation_retains_failed_case_and_releases_after_cleanup(self):
        for module in SUITE_ENTRYPOINTS:
            for signum in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(entrypoint=module.__name__, signal=signum):
                    probe = self.probe(module, real_suite=True)
                    probe.record_cases = True
                    probe.on_event["case.advertisement_and_gatt"] = lambda: self.registry.send(signum)
                    result, report = probe.invoke()
                    self.assertEqual(result, 1)
                    self.assertEqual(report["code"], "HIL_INTERRUPTED")
                    self.assertTrue(report["interrupted"])
                    self.assertFalse(report["cases"][-1]["ok"])
                    self.assertEqual(report["cases"][-1]["code"], "HIL_INTERRUPTED")
                    self.assertIn("media.command.0", probe.events)
                    self.assertIn("media.command.4", probe.events)
                    self.assertIn("uart.closed", probe.events)
                    self.assertEqual(probe.events[-1], "lock.release")
                    self.assert_restored()

    def test_uncertain_provisioning_is_failed_once_without_resend_erase_or_reboot(self):
        for module in SUITE_ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module, real_suite=(module is hardware_e2e))
                probe.record_cases = probe.real_provision = True
                probe.wifi = ("FixtureAP", "FixturePassword")
                if module is hardware_e2e:
                    probe.case_operations["wifi_provisioning"] = lambda: {
                        "bytes": probe.suite.provision(*probe.wifi)}
                probe.on_event["client.wifi_config_put"] = lambda: self.registry.send(signal.SIGTERM)
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_INTERRUPTED")
                self.assertTrue(report["configuration_may_require_recovery"])
                self.assertEqual(probe.events.count("client.wifi_config_put"), 1)
                self.assertNotIn("client.wifi_erase", probe.events)
                self.assertNotIn("client.reboot", probe.events)
                failed_case = report["cases"][-1]
                self.assertEqual(failed_case["name"], "wifi_provisioning" if module is hardware_e2e else "missing_ap_provisioning")
                self.assertFalse(failed_case["ok"])
                self.assertEqual(failed_case["code"], "HIL_INTERRUPTED")
                self.assertIn("media.command.0", probe.events)
                self.assertIn("media.command.4", probe.events)
                self.assertEqual(probe.events[-1], "lock.release")
                self.assert_restored()

    def test_signals_during_resource_acquisition_never_escape_before_cleanup(self):
        for module in ENTRYPOINTS:
            operations = ("lock.acquire", "serial.construct", "serial.open") if module is boot_smoke else (
                "lock.acquire", "client.construct", "suite.construct", "uart.construct", "uart.enter")
            for operation in operations:
                with self.subTest(entrypoint=module.__name__, operation=operation):
                    probe = self.probe(module)
                    probe.on_event[operation] = lambda: self.registry.send(signal.SIGINT)
                    result, report = probe.invoke()
                    self.assertEqual(result, 1)
                    self.assertEqual(report["code"], "BOOT_INTERRUPTED" if module is boot_smoke else "HIL_INTERRUPTED")
                    self.assertEqual(probe.events[-1], "lock.release")
                    if operation in ("serial.construct", "serial.open"):
                        self.assertIn("serial.closed", probe.events)
                        self.assertEqual(probe.closed_lines, {"dtr": False, "rts": False})
                    elif operation == "uart.enter":
                        self.assertIn("uart.closed", probe.events)
                        self.assertIn("client.disconnected.1", probe.events)
                    elif operation in ("client.construct", "suite.construct", "uart.construct"):
                        self.assertIn("client.disconnected.1", probe.events)
                    self.assert_restored()

    def test_signal_during_boot_read_fails_and_both_lines_close_under_lock(self):
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum):
                probe = self.probe(boot_smoke)
                probe.on_event["serial.read"] = lambda: self.registry.send(signum)
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "BOOT_INTERRUPTED")
                self.assertFalse(probe.output.exists())
                self.assertEqual(probe.closed_lines, {"dtr": False, "rts": False})
                self.assertEqual(probe.events[-3:], ["serial.close", "serial.closed", "lock.release"])
                self.assert_restored()

    def test_first_signal_during_cleanup_invalidates_success_without_interrupting_cleanup(self):
        for module in ENTRYPOINTS:
            operation = "serial.dtr.2.False" if module is boot_smoke else "uart.exit"
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module)
                probe.on_event[operation] = lambda: self.registry.send(signal.SIGTERM)
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertFalse(report["ok"])
                self.assertEqual(report["code"], "BOOT_INTERRUPTED" if module is boot_smoke else "HIL_INTERRUPTED")
                self.assertEqual(probe.events[-1], "lock.release")
                self.assertIn("serial.closed" if module is boot_smoke else "uart.closed", probe.events)
                self.assert_restored()

    def test_double_signal_cannot_interrupt_ble_udp_uart_or_lock_cleanup(self):
        for udp in (False, True):
            with self.subTest(udp=udp):
                probe = self.probe(hardware_e2e, real_suite=True)
                probe.record_cases = True
                probe.udp_suite = udp
                probe.on_event["case.advertisement_and_gatt"] = lambda: self.registry.send(signal.SIGINT)
                cleanup_events = ("udp.control.0", "udp.control.4", "udp.close") if udp else (
                    "media.command.0", "media.command.4")
                for operation in (*cleanup_events, "client.disconnect.1", "uart.exit", "client.disconnect.2", "lock.release"):
                    probe.on_event[operation] = lambda: self.registry.send(signal.SIGTERM)
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_INTERRUPTED")
                self.assertEqual(report["cleanup_errors"], [])
                for event in cleanup_events:
                    self.assertIn(event, probe.events)
                self.assertIn("uart.closed", probe.events)
                self.assertIn("client.disconnected.2", probe.events)
                self.assertEqual(probe.events[-1], "lock.release")
                self.assert_restored()

    def test_original_error_and_cleanup_details_survive_signals_during_teardown(self):
        for module, operation in ((hardware_e2e, "suite.run"), (wifi_retry_hil, "retry.evidence"),
                                  (boot_smoke, "serial.read")):
            with self.subTest(entrypoint=module.__name__):
                cleanup = "serial.dtr.2.False" if module is boot_smoke else "uart.exit"
                probe = self.probe(module, failures={operation: TestbenchError("TB_ORIGINAL_FAILURE"),
                                                    cleanup: OSError("private cleanup detail")})
                probe.on_event[cleanup] = lambda: self.registry.send(signal.SIGTERM)
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "TB_ORIGINAL_FAILURE")
                self.assertTrue(report["interrupted"])
                key = "uart_cleanup_errors" if module is wifi_retry_hil else "cleanup_errors"
                self.assertEqual(report[key], ["OSError"])
                self.assertNotIn("private", json.dumps(report))
                self.assertEqual(probe.events[-1], "lock.release")
                self.assert_restored()

    def test_cancelled_operation_keeps_interruption_code_after_multiple_teardown_failures(self):
        for module in ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                if module is boot_smoke:
                    failures = {"serial.dtr.2.False": OSError("private DTR failure"),
                                "serial.rts.4.False": RuntimeError("private RTS failure"),
                                "serial.close": OSError("private close failure")}
                    operation = "serial.read"
                else:
                    failures = {"media.command.0": OSError("private pause failure"),
                                "uart.exit": RuntimeError("private UART failure"),
                                f"client.disconnect.{2 if module is hardware_e2e else 1}": OSError("private disconnect failure")}
                    operation = "case.advertisement_and_gatt"
                probe = self.probe(module, failures=failures, real_suite=(module in SUITE_ENTRYPOINTS))
                probe.record_cases = True
                probe.on_event[operation] = lambda: self.registry.send(signal.SIGINT)
                result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "BOOT_INTERRUPTED" if module is boot_smoke else "HIL_INTERRUPTED")
                self.assertFalse(report["ok"])
                self.assertEqual(probe.events[-1], "lock.release")
                self.assertIn("serial.closed" if module is boot_smoke else "uart.closed", probe.events)
                if module is boot_smoke:
                    self.assertEqual(report["cleanup_errors"], ["OSError", "RuntimeError", "OSError"])
                elif module is hardware_e2e:
                    self.assertEqual(report["cleanup_errors"], ["OSError", "RuntimeError", "OSError"])
                else:
                    self.assertEqual(report["cleanup_errors"], ["OSError"])
                    self.assertEqual(report["uart_cleanup_errors"], ["RuntimeError"])
                    self.assertEqual(report["cleanup_error_type"], "OSError")
                self.assertNotIn("private", json.dumps(report))
                self.assert_restored()

    def test_report_is_selected_and_written_only_after_all_teardown(self):
        original = Path.write_text
        for module in SUITE_ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module)

                def write(path, *args, **kwargs):
                    if path.name == "results.json":
                        self.assertFalse(probe.held)
                        self.assertFalse(probe.uart_open)
                        self.assertEqual(probe.events[-1], "lock.release")
                    return original(path, *args, **kwargs)

                probe.on_event["lock.release"] = lambda: self.registry.send(signal.SIGINT)
                with patch.object(Path, "write_text", autospec=True, side_effect=write):
                    result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertEqual(report["code"], "HIL_INTERRUPTED")
                self.assertFalse(report["ok"])
                self.assert_restored()

    def test_handlers_restore_after_success_failure_and_cancelled_acquisition(self):
        for module in ENTRYPOINTS:
            for failure in (False, True):
                with self.subTest(entrypoint=module.__name__, failure=failure):
                    operation = "serial.open" if module is boot_smoke else "uart.enter"
                    probe = self.probe(module, failures={operation: OSError("private fixture error")} if failure else None)
                    probe.invoke()
                    self.assert_restored()

    def test_partial_handler_install_failure_restores_handlers_without_acquiring_hardware(self):
        def install(signum, handler):
            if signum == signal.SIGTERM and handler is not self.registry.previous[signum]:
                raise RuntimeError("HIL_SIGNAL_INSTALL_FAILED")
            self.registry.install(signum, handler)

        for module in ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module)
                with patch("standalone_signals.signal.signal", side_effect=install):
                    result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertFalse(report["ok"])
                probe.lock_factory.assert_not_called()
                self.assert_restored()

    def test_handler_restore_failure_attempts_other_handler_and_cannot_pass(self):
        def install(signum, handler):
            self.registry.install(signum, handler)
            if signum == signal.SIGINT and handler is self.registry.previous[signum]:
                raise OSError("private signal restore failure")

        for module in ENTRYPOINTS:
            with self.subTest(entrypoint=module.__name__):
                probe = self.probe(module)
                with patch("standalone_signals.signal.signal", side_effect=install):
                    result, report = probe.invoke()
                self.assertEqual(result, 1)
                self.assertFalse(report["ok"])
                self.assertEqual(report["cleanup_errors"], ["OSError"])
                self.assertNotIn("private", json.dumps(report))
                self.assertEqual(self.registry.calls[-1], (signal.SIGTERM, self.registry.previous[signal.SIGTERM]))
                self.assert_restored()

    def test_non_main_thread_does_not_install_process_handlers(self):
        errors = []

        def worker():
            try:
                with StandaloneSignals() as scope:
                    scope.request(signal.SIGINT)
                    with self.assertRaises(StandaloneInterrupted):
                        scope.checkpoint()
            except BaseException as error:
                errors.append(error)

        thread = threading.Thread(target=worker)
        thread.start()
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(self.registry.calls, [])
        self.assert_restored()

    def test_uart_wait_ble_delay_and_udp_frame_wait_cooperate_before_timeout(self):
        for kind in ("uart", "ble", "udp"):
            with self.subTest(wait=kind):
                scope = StandaloneSignals()
                clock = [0.0]

                def sleep(seconds):
                    clock[0] += seconds
                    scope.request(signal.SIGTERM)

                with patch("standalone_signals.time.monotonic", side_effect=lambda: clock[0]), \
                     patch("standalone_signals.time.sleep", side_effect=sleep):
                    if kind == "uart":
                        uart = hardware_helpers.UARTLog("unused-fixture", self.directory / "unused.log")
                        scope.bind_uart(uart)
                        operation = lambda: uart.wait("unavailable", 0)
                    elif kind == "ble":
                        client = SimpleNamespace(pump=Mock())
                        scope.bind_client(client)
                        operation = lambda: client.pump(100)
                    else:
                        receiver = object.__new__(hardware_helpers.UdpFrames)
                        receiver.socket = Mock()
                        receiver.socket.recvfrom.side_effect = BlockingIOError
                        scope.bind_udp(receiver)
                        operation = receiver.next_frame
                    with self.assertRaisesRegex(StandaloneInterrupted, "^HIL_INTERRUPTED$"):
                        operation()
                self.assertLessEqual(clock[0], hardware_helpers.POLL_SECONDS)
                self.assertFalse((self.directory / "unused.log").exists())

    def test_actual_sigint_sigterm_are_requests_not_asynchronous_exceptions(self):
        previous = {signum: NATIVE_GETSIGNAL(signum) for signum in (signal.SIGINT, signal.SIGTERM)}
        with patch("standalone_signals.signal.signal", side_effect=NATIVE_SIGNAL), \
             patch("standalone_signals.signal.getsignal", side_effect=NATIVE_GETSIGNAL):
            with StandaloneSignals() as scope:
                signal.raise_signal(signal.SIGINT)
                self.assertEqual(scope.signum, signal.SIGINT)
                with self.assertRaises(StandaloneInterrupted):
                    scope.checkpoint()
                scope.begin_cleanup()
                for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGTERM):
                    signal.raise_signal(signum)
                    scope.checkpoint()
                self.assertEqual(scope.signum, signal.SIGINT)
        self.assertEqual({signum: NATIVE_GETSIGNAL(signum) for signum in previous}, previous)

    def test_double_signal_during_boot_cleanup_still_attempts_both_lines_and_close(self):
        probe = self.probe(boot_smoke)
        probe.on_event["serial.read"] = lambda: self.registry.send(signal.SIGINT)
        for operation in ("serial.dtr.2.False", "serial.rts.4.False", "serial.close", "lock.release"):
            probe.on_event[operation] = lambda: self.registry.send(signal.SIGTERM)
        result, report = probe.invoke()
        self.assertEqual(result, 1)
        self.assertEqual(report["code"], "BOOT_INTERRUPTED")
        self.assertEqual(report["cleanup_errors"], [])
        self.assertEqual(probe.closed_lines, {"dtr": False, "rts": False})
        self.assertEqual(probe.events[-3:], ["serial.close", "serial.closed", "lock.release"])
        self.assert_restored()

    def test_read_only_subprocess_wait_is_cancelled_reaped_and_pipes_closed(self):
        for acquisition in (False, True):
            with self.subTest(during_acquisition=acquisition):
                scope = StandaloneSignals()
                command = ["fixture-read-only-query"]
                process = SimpleNamespace(stdout=Mock(), stderr=Mock(), returncode=None,
                                          poll=Mock(return_value=None), kill=Mock())

                def communicate(**kwargs):
                    if kwargs:
                        scope.request(signal.SIGINT)
                        raise subprocess.TimeoutExpired(command, kwargs["timeout"])
                    scope.request(signal.SIGTERM)
                    return "private credential output", "private stderr"

                process.communicate = Mock(side_effect=communicate)
                def construct(*args, **kwargs):
                    if acquisition:
                        scope.request(signal.SIGINT)
                    return process

                with patch("standalone_signals.subprocess.Popen", side_effect=construct), \
                     self.assertRaisesRegex(StandaloneInterrupted, "^HIL_INTERRUPTED$"):
                    scope.command_output(command, hardware_e2e.NMCLI_TIMEOUT_SECONDS)
                process.kill.assert_called_once()
                process.stdout.close.assert_called_once()
                process.stderr.close.assert_called_once()
                self.assertEqual(process.communicate.call_count, 1 if acquisition else 2)
                self.assertEqual(scope.cleanup_errors, [])
                # A local child cleanup must not disable later cancellation checks.
                with self.assertRaises(StandaloneInterrupted):
                    scope.checkpoint()

    def test_subprocess_timeout_and_cleanup_failures_keep_original_code_and_attempt_both_pipes(self):
        scope = StandaloneSignals()
        process = SimpleNamespace(stdout=Mock(), stderr=Mock(), returncode=None,
                                  poll=Mock(return_value=None), kill=Mock(side_effect=OSError("private kill error")),
                                  communicate=Mock(side_effect=OSError("private wait error")))
        process.stdout.close.side_effect = OSError("private stdout close error")
        with patch("standalone_signals.subprocess.Popen", return_value=process), \
             patch("standalone_signals.time.monotonic", side_effect=[0, hardware_e2e.NMCLI_TIMEOUT_SECONDS]), \
             self.assertRaisesRegex(RuntimeError, "^HIL_WIFI_PROFILE_TIMEOUT$"):
            scope.command_output(["fixture-read-only-query"], hardware_e2e.NMCLI_TIMEOUT_SECONDS)
        process.kill.assert_called_once()
        process.communicate.assert_called_once_with()
        process.stdout.close.assert_called_once()
        process.stderr.close.assert_called_once()
        self.assertEqual(scope.cleanup_errors, ["OSError", "OSError", "OSError"])

    def test_owned_release_failure_does_not_replace_body_error(self):
        scope = StandaloneSignals()
        failure = TestbenchError("TB_ORIGINAL_FAILURE")
        resource = Mock(__enter__=Mock(return_value=object()),
                        __exit__=Mock(side_effect=OSError("private release error")),
                        cleanup_errors=[])
        with self.assertRaises(TestbenchError) as raised:
            with scope.owned(resource):
                raise failure
        self.assertIs(raised.exception, failure)
        resource.__exit__.assert_called_once()
        self.assertEqual(scope.cleanup_errors, ["OSError"])

    def test_subprocess_poll_failure_does_not_skip_kill_reap_or_either_pipe(self):
        scope = StandaloneSignals()
        process = SimpleNamespace(stdout=Mock(), stderr=Mock(), returncode=None,
                                  poll=Mock(side_effect=OSError("private poll error")), kill=Mock(),
                                  communicate=Mock(return_value=("private output", "private stderr")))
        with patch("standalone_signals.subprocess.Popen", return_value=process), \
             patch("standalone_signals.time.monotonic", side_effect=[0, hardware_e2e.NMCLI_TIMEOUT_SECONDS]), \
             self.assertRaisesRegex(RuntimeError, "^HIL_WIFI_PROFILE_TIMEOUT$"):
            scope.command_output(["fixture-read-only-query"], hardware_e2e.NMCLI_TIMEOUT_SECONDS)
        process.kill.assert_called_once()
        process.communicate.assert_called_once_with()
        process.stdout.close.assert_called_once()
        process.stderr.close.assert_called_once()
        self.assertEqual(scope.cleanup_errors, ["OSError"])

    def test_local_flash_cleanup_error_and_signal_preserve_original_case_failure(self):
        scope = StandaloneSignals()
        client = Mock(rx=None)
        suite = hardware_e2e.HardwareSuite(client, self.directory, None)
        suite.interruption = scope
        primary = TestbenchError("TB_FLASH_OPERATION_FAILED")

        def command(code, *_):
            if code == hardware_e2e.CMD_FLASH_ON:
                raise primary
            scope.request(signal.SIGTERM)
            scope.checkpoint()
            raise OSError("private flash cleanup failure")

        client.command.side_effect = command
        with self.assertRaises(TestbenchError) as raised:
            suite.case("flashlight", suite.flashlight)
        self.assertIs(raised.exception, primary)
        self.assertEqual(suite.records[-1]["code"], primary.code)
        self.assertEqual(suite.cleanup_errors, ["OSError"])
        self.assertEqual([call.args[0] for call in client.command.call_args_list],
                         [hardware_e2e.CMD_FLASH_ON, hardware_e2e.CMD_FLASH_OFF])


if __name__ == "__main__":
    unittest.main()
