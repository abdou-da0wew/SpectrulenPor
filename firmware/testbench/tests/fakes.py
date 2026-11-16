"""Deterministic hardware fakes; no BlueZ, serial, decoder or UDP dependencies."""

import threading
import time
from collections import deque

from testbench.engine import HardwareEngine
from testbench.transport import WIRE

FAKE_JPEG = b"\xff\xd8test-frame\xff\xd9"


class FakeLock:
    held = set()
    mutex = threading.Lock()

    def __init__(self, adapter, uart):
        self.resources = {adapter}
        if uart:
            self.resources.add(uart)
        self.acquired = False

    def acquire(self):
        from testbench.errors import TestbenchError
        with self.mutex:
            if self.held & self.resources:
                raise TestbenchError("TB_HARDWARE_LOCKED", "HARDWARE_LOCKED", 409)
            self.held.update(self.resources)
            self.acquired = True

    def release(self):
        with self.mutex:
            if self.acquired:
                self.held.difference_update(self.resources)
                self.acquired = False


class FakeClient:
    def __init__(self, adapter, cooperate, on_frame):
        self.owner = threading.get_ident()
        self.cooperate, self.on_frame = cooperate, on_frame
        self.rx = self.tx = None
        self.frames, self.lines = deque(), deque()
        self.commands = []
        self.provisions = 0
        self.paired = self.streaming = self.flash = False
        self.esp_mac = self.esp_hostname = None
        self.device_path = "/fake/esp"
        self.connected = False
        self.manager = self
        self.protocol_errors = 0
        self.fail_provision = False
        self.fail_identity = False
        self.connect_wait = None

    def check(self):
        assert threading.get_ident() == self.owner
        self.cooperate()

    def connect(self):
        self.check()
        if self.connect_wait is not None:
            while not self.connect_wait.is_set():
                self.check()
                time.sleep(0.001)
        self.rx = self.tx = object()
        self.connected = True
        return {}

    def status(self):
        self.check()
        return {"bt": "1", "wifi": "disconnected", "stream": "1" if self.streaming else "0",
                "flash": "1" if self.flash else "0"}

    def pair(self, code):
        self.check()
        assert code == WIRE.BLE_PAIRING_CODE
        self.paired = True

    def wifi_config_put(self, ssid, password):
        self.check()
        self.provisions += 1
        if self.fail_provision:
            raise TimeoutError("HIL_REPLY_TIMEOUT")
        return len(ssid.encode()) + len(password.encode()) + 3

    def line(self, prefix, since, timeout=10):
        self.check()
        if self.fail_identity:
            raise TimeoutError("HIL_REPLY_TIMEOUT")
        return prefix + ("AA:BB:CC:DD:EE:FF" if prefix == "$ESP_MAC:" else "spectrulenpor-esp32")

    def reboot(self):
        self.check()
        self.commands.append(WIRE.CMD_REBOOT)
        self.connected = False

    def wait(self, predicate, timeout, code):
        self.check()
        result = predicate()
        if not result:
            raise TimeoutError(code)
        return result

    def GetManagedObjects(self):
        self.check()
        return {self.device_path: {WIRE.DEVICE: {"Connected": self.connected}}}

    def command(self, code, ack=None):
        self.check()
        self.commands.append(code)
        if code == WIRE.CMD_STREAM_ON:
            self.streaming = True
        elif code == WIRE.CMD_STREAM_OFF:
            self.streaming = False
        elif code == WIRE.CMD_SINGLE_FRAME:
            self.frames.append((time.monotonic(), FAKE_JPEG))
        elif code == WIRE.CMD_FLASH_ON:
            self.flash = True
        elif code == WIRE.CMD_FLASH_OFF:
            self.flash = False
        return ack

    def pump(self, seconds=0):
        self.check()
        if self.streaming:
            self.frames.append((time.monotonic(), FAKE_JPEG))

    def frame(self, timeout=12):
        self.check()
        if not self.frames:
            self.pump()
        if not self.frames:
            raise TimeoutError("HIL_BLE_FRAME_TIMEOUT")
        stamp, data = self.frames.popleft()
        self.on_frame(stamp, data, "ble")
        return stamp, data

    def clear_frames(self):
        self.check()
        self.frames.clear()

    def disconnect(self):
        self.check()
        self.connected = self.paired = self.streaming = self.flash = False
        self.rx = self.tx = None
        self.frames.clear()


def fake_engine(**kwargs):
    clients = []

    def factory(*arguments):
        client = FakeClient(*arguments)
        clients.append(client)
        return client

    engine = HardwareEngine(client_factory=factory, lock_factory=FakeLock,
                            decoder=lambda data: (320, 240), **kwargs)
    engine.fake_clients = clients
    return engine


def wait_job(engine, timeout=3):
    deadline = time.monotonic() + timeout
    while engine.snapshot()["busy"]:
        if time.monotonic() >= deadline:
            raise AssertionError("fake job did not finish")
        time.sleep(0.002)
    return engine.snapshot()["job"]
