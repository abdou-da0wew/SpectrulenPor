import sys
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

from testbench.errors import TestbenchError
from testbench.hardware_lock import HardwareLock
from testbench.transport import MemoryUART


class OwnershipTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "linux", "Linux flock adapter")
    def test_adapter_and_uart_are_both_exclusive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = HardwareLock("hci0", "fake-uart", root).acquire()
            try:
                for adapter, uart in (("hci0", None), ("hci1", "fake-uart")):
                    with self.assertRaises(TestbenchError) as caught:
                        HardwareLock(adapter, uart, root).acquire()
                    self.assertEqual(caught.exception.code, "TB_HARDWARE_LOCKED")
            finally:
                first.release()
            with HardwareLock("hci0", "fake-uart", root):
                self.assertTrue(list(root.glob("*.lock")))

    @unittest.skipUnless(sys.platform == "linux", "Linux flock adapter")
    def test_symlink_uart_alias_has_same_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            device = root / "device"
            device.touch()
            alias = root / "alias"
            alias.symlink_to(device)
            lock_root = root / "locks"
            with HardwareLock("hci0", str(device), lock_root):
                with self.assertRaises(TestbenchError):
                    HardwareLock("hci1", str(alias), lock_root).acquire()

    def test_platform_is_gated_without_loading_dbus(self):
        with patch("testbench.hardware_lock.sys.platform", "win32"):
            with self.assertRaises(TestbenchError) as caught:
                HardwareLock().acquire()
        self.assertEqual(caught.exception.code, "TB_BLUEZ_REQUIRES_LINUX")

    def test_uart_uses_in_memory_evidence_no_log_thread(self):
        uart = MemoryUART("fake-port")
        self.assertIsNone(uart.path)
        self.assertIsNone(uart.thread)
        uart.data.extend(b"one\noperation=boot.mode mode=ble_setup ble=1\n")
        self.assertEqual(uart.wait(r"operation=boot.mode", 0, timeout=0.1).group(), "operation=boot.mode")
        self.assertEqual(uart.wait_count(r"one", 1, 0, timeout=0.1), 1)
        uart.__exit__(None, None, None)
        self.assertFalse(uart.data)

    def test_uart_wait_injects_cooperative_pump(self):
        calls = []
        uart = MemoryUART("fake-port", cooperate=lambda: calls.append(1))
        with self.assertRaises(TimeoutError):
            uart.wait("never", 0, timeout=0.02)
        self.assertTrue(calls)

    def test_uart_read_rejects_second_thread(self):
        uart = MemoryUART("fake-port")
        errors = []

        def wrong_thread():
            try:
                uart.poll()
            except TestbenchError as error:
                errors.append(error.code)

        worker = threading.Thread(target=wrong_thread)
        worker.start()
        worker.join()
        self.assertEqual(errors, ["TB_HARDWARE_THREAD_VIOLATION"])

    def test_uart_open_failure_closes_partial_serial_without_disk_evidence(self):
        serial = Mock(spec=["port", "dtr", "rts", "open", "close"])
        original = OSError("fixture open failure")
        serial.open.side_effect = original
        module = SimpleNamespace(Serial=Mock(return_value=serial))
        uart = MemoryUART("fake-port")
        with patch.dict(sys.modules, {"serial": module}), patch.object(Path, "open") as file_open:
            with self.assertRaises(OSError) as caught:
                uart.__enter__()
        self.assertIs(caught.exception, original)
        serial.close.assert_called_once()
        self.assertIsNone(uart.uart)
        file_open.assert_not_called()

    def test_uart_close_failure_still_clears_sensitive_memory(self):
        uart = MemoryUART("fake-port")
        serial = Mock(spec=["dtr", "rts", "close"])
        serial.close.side_effect = OSError("fixture close failure")
        uart.uart = serial
        uart.data.extend(b"fixture private evidence")
        with self.assertRaisesRegex(RuntimeError, "^HIL_UART_CLEANUP_INCOMPLETE$"):
            uart.__exit__(None, None, None)
        self.assertFalse(uart.data)
        self.assertIsNone(uart.uart)
        self.assertEqual(uart.cleanup_errors, ["OSError"])

    def test_uart_cleanup_does_not_mask_original_operation_failure(self):
        serial = Mock(spec=["port", "dtr", "rts", "open", "close"])
        serial.close.side_effect = OSError("fixture close failure")
        module = SimpleNamespace(Serial=Mock(return_value=serial))
        uart = MemoryUART("fake-port")
        original = TimeoutError("HIL_ORIGINAL_FAILURE")
        with patch.dict(sys.modules, {"serial": module}):
            with self.assertRaises(TimeoutError) as caught:
                with uart:
                    uart.data.extend(b"fixture private evidence")
                    raise original
        self.assertIs(caught.exception, original)
        self.assertFalse(uart.data)
        self.assertEqual(uart.cleanup_errors, ["OSError"])

    def test_uart_constructor_failure_does_not_require_a_serial_instance_for_cleanup(self):
        original = OSError("fixture constructor failure")
        module = SimpleNamespace(Serial=Mock(side_effect=original))
        uart = MemoryUART("fake-port")
        with patch.dict(sys.modules, {"serial": module}):
            with self.assertRaises(OSError) as caught:
                uart.__enter__()
        self.assertIs(caught.exception, original)
        uart.__exit__(None, None, None)
        self.assertIsNone(uart.uart)


if __name__ == "__main__":
    unittest.main()
