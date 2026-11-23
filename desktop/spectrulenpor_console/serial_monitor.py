"""Non-invasive USB UART log reader for ESP32 diagnostic telemetry."""
from __future__ import annotations
import glob
import re
import threading
import time
from typing import Callable

TELEMETRY_FIELDS = (
    "fps_x100", "frames", "last_bytes", "fragments", "parity",
    "retry_packets", "retry_attempts", "retry_wait_ms", "heap",
    "min_heap", "rssi", "frame_ms", "profile", "errors",
)

def serial_ports() -> list[str]:
    paths = sorted(set(glob.glob("/dev/ttyUSB*") + glob.glob("/dev/ttyACM*")))
    return paths

def parse_uart_metrics(line: str) -> dict:
    values = {}
    for key, value in re.findall(r"([A-Za-z_][A-Za-z0-9_]*)=(-?\d+)", line):
        if key in TELEMETRY_FIELDS:
            values[key] = int(value)
    return values

class SerialMonitor:
    def __init__(self, port: str, on_line: Callable[[str], None],
                 on_state: Callable[[str], None] | None = None, baud: int = 115200):
        self.port, self.baud = port, baud
        self.on_line, self.on_state = on_line, on_state
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._serial = None

    def start(self):
        if self._thread and self._thread.is_alive():
            raise RuntimeError("Serial monitor is already running")
        try:
            import serial
        except ImportError as exc:
            raise RuntimeError("pyserial is not installed for this Python interpreter") from exc
        device = serial.Serial()
        device.port = self.port
        device.baudrate = self.baud
        device.timeout = 0.2
        device.write_timeout = 1
        device.dsrdtr = False
        device.rtscts = False
        device.dtr = False
        device.rts = False
        device.open()
        self._serial = device
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="spectrulenpor-uart", daemon=True)
        self._thread.start()
        if self.on_state: self.on_state("connected")

    def _run(self):
        pending = bytearray()
        try:
            while not self._stop.is_set() and self._serial:
                chunk = self._serial.read(4096)
                if not chunk:
                    continue
                pending.extend(chunk)
                while b"\n" in pending:
                    raw, _, rest = pending.partition(b"\n")
                    pending = bytearray(rest)
                    line = raw.decode("utf-8", errors="replace").strip("\r\x00")
                    if line and self.on_line:
                        self.on_line(line)
            if pending and self.on_line:
                self.on_line(pending.decode("utf-8", errors="replace"))
        except Exception as exc:
            if not self._stop.is_set() and self.on_state:
                self.on_state(f"error: {exc}")
        finally:
            if self._serial:
                try: self._serial.close()
                except Exception: pass
                self._serial = None
            if self.on_state: self.on_state("disconnected")

    def stop(self):
        self._stop.set()
        if self._serial:
            try: self._serial.close()
            except Exception: pass
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.0)
        self._thread = None
