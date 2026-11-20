"""Linux BlueZ and UART clients for testing the physically attached glasses."""

import io
import ipaddress
import re
import socket
import struct
import sys
import threading
import time
from collections import deque
from pathlib import Path

BLUEZ = "org.bluez"
PROPERTIES = "org.freedesktop.DBus.Properties"
OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
DEVICE = "org.bluez.Device1"
ADAPTER = "org.bluez.Adapter1"
SERVICE = "org.bluez.GattService1"
CHARACTERISTIC = "org.bluez.GattCharacteristic1"
DESCRIPTOR = "org.bluez.GattDescriptor1"
SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb"
TX_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb"
RX_UUID = "0000ffe2-0000-1000-8000-00805f9b34fb"
CCCD_UUID = "00002902-0000-1000-8000-00805f9b34fb"
MAX_FRAME_BYTES = 512 * 1024
MAX_TEXT_BYTES = 4096
UDP_HEADER = struct.Struct("<IIIIII")
UDP_PORT = 8888
UDP_PAYLOAD_BYTES = 1200
UDP_FEC_GROUP_SIZE = 4
UDP_PARITY_SEQUENCE_FLAG = 0x80000000
UDP_RECEIVE_BYTES = 1500
UART_BAUD = 115200
UART_READ_TIMEOUT_SECONDS = 0.1
UART_RESET_SECONDS = 0.1
UART_WAIT_SECONDS = 15
POLL_SECONDS = 0.01

# Command bytes (mirrored in firmware config.h)
CMD_STREAM_ON = 0x01
CMD_STREAM_OFF = 0x00
CMD_SINGLE_FRAME = 0x02
CMD_FLASH_ON = 0x03
CMD_FLASH_OFF = 0x04
CMD_RESTART = 0x05
CMD_SHUTDOWN = 0x06
CMD_WIFI_CONFIG_PUT = 0x07
CMD_WIFI_CONFIG_GET = 0x08
CMD_CONNECTION_STATUS = 0x09
CMD_BLE_PAIR = 0x0A      # pairing code "11111"
CMD_REBOOT = 0x0B        # reboot ESP after WiFi setup
CMD_UDP_KEEPALIVE = 0x0C # re-register UDP video/control peer

BLE_PAIRING_CODE = "11111"


def require(condition: bool, code: str) -> None:
    if not condition:
        raise AssertionError(code)


def is_gatt_rejection(error) -> bool:
    """Match ATT value/length rejection, never disconnected or timed-out writes."""
    return (error.get_dbus_name(), error.get_dbus_message()) in (
        ("org.bluez.Error.Failed", "Operation failed with ATT error: 0x13"),
        ("org.bluez.Error.InvalidArguments", "Invalid Length"),
    )


def decode_jpeg(
    data: bytes,
    expected_size: tuple[int, int] | frozenset[tuple[int, int]],
    path: Path,
) -> dict:
    from PIL import Image, ImageStat

    require(data.startswith(b"\xff\xd8") and data.endswith(b"\xff\xd9"), "HIL_JPEG_MARKERS")
    with Image.open(io.BytesIO(data)) as image:
        image.load()
        require(image.format == "JPEG", "HIL_IMAGE_FORMAT")
        if isinstance(expected_size, frozenset):
            require(image.size in expected_size, "HIL_IMAGE_DIMENSIONS")
        else:
            require(image.size == expected_size, "HIL_IMAGE_DIMENSIONS")
        luminance = ImageStat.Stat(image.convert("L")).mean[0]
        width, height = image.size
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)
    return {"bytes": len(data), "width": width, "height": height, "mean_luminance": round(luminance, 2)}


class UARTLog:
    def __init__(self, port: str, path: Path, baud: int = UART_BAUD):
        self.port, self.path, self.baud = port, path, baud
        self.stopped = threading.Event()
        self.error = None
        self.data = bytearray()
        self.lock = threading.Lock()
        self.uart = self.output = self.thread = None
        self.cleanup_errors = []

    def __enter__(self):
        import serial

        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            self.output = self.path.open("wb")
            self.uart = serial.Serial(port=None, baudrate=self.baud,
                                      timeout=UART_READ_TIMEOUT_SECONDS)
            self.uart.port = self.port
            self.uart.dtr = False
            self.uart.rts = False
            self.uart.open()
            self.thread = threading.Thread(target=self._read, daemon=True)
            self.thread.start()
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def _read(self):
        try:
            while not self.stopped.is_set():
                data = self.uart.read(max(1, self.uart.in_waiting))
                if data:
                    self.output.write(data)
                    self.output.flush()
                    with self.lock:
                        self.data.extend(data)
        except OSError as exc:
            if not self.stopped.is_set():
                self.error = type(exc).__name__

    def mark(self) -> int:
        with self.lock:
            return len(self.data)

    def text(self, since: int = 0) -> str:
        with self.lock:
            return bytes(self.data[since:]).decode("utf-8", errors="replace")

    def wait(self, pattern: str, since: int, timeout: float = UART_WAIT_SECONDS,
              code: str = "HIL_UART_REPLY_TIMEOUT", pump=None):
        expression = re.compile(pattern)
        return self.wait_for(lambda text: expression.search(text), since, timeout, code, pump)

    def wait_count(self, pattern: str, count: int, since: int,
                   timeout: float = UART_WAIT_SECONDS,
                   code: str = "HIL_UART_REPLY_TIMEOUT", pump=None) -> int:
        """Count independent matches without repeated-pattern backtracking."""
        require(count > 0, "HIL_UART_INVALID_MATCH_COUNT")
        expression = re.compile(pattern)

        def enough(text):
            observed = sum(1 for _ in expression.finditer(text))
            return observed if observed >= count else None

        return self.wait_for(enough, since, timeout, code, pump)

    def wait_for(self, predicate, since: int, timeout: float = UART_WAIT_SECONDS,
                 code: str = "HIL_UART_REPLY_TIMEOUT", pump=None):
        """Evaluate fresh evidence only; keep capture failures and deadlines visible."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            require(self.error is None, "HIL_UART_CAPTURE_ERROR")
            result = predicate(self.text(since))
            if result:
                return result
            if pump is not None:
                pump()
            time.sleep(POLL_SECONDS)
        raise TimeoutError(code)

    def reset(self) -> int:
        """Reset EN without grounding GPIO0; keep capturing the new boot."""
        since = self.mark()
        self.uart.dtr = False
        self.uart.rts = True
        time.sleep(UART_RESET_SECONDS)
        self.uart.rts = False
        return since

    def _close_uart(self):
        """Try both reset lines and close independently, even after partial open."""
        if self.uart is None:
            return
        try:
            for line in ("dtr", "rts"):
                try:
                    setattr(self.uart, line, False)
                except Exception as error:
                    self.cleanup_errors.append(type(error).__name__)
            try:
                self.uart.close()
            except Exception as error:
                self.cleanup_errors.append(type(error).__name__)
        finally:
            self.uart = None

    def __exit__(self, exc_type, *_):
        self.stopped.set()
        try:
            if self.thread is not None and self.thread.ident is not None:
                # Reads have a finite timeout. Never release hardware ownership
                # while the reader can still touch UART or its evidence file.
                self.thread.join()
        finally:
            self.thread = None
            self._close_uart()
            if self.output is not None:
                try:
                    self.output.close()
                except Exception as error:
                    self.cleanup_errors.append(type(error).__name__)
                finally:
                    self.output = None
        if self.cleanup_errors and exc_type is None:
            raise RuntimeError("HIL_UART_CLEANUP_INCOMPLETE") from None


class BluezClient:
    def __init__(self, adapter: str = "hci0", name: str = "SpectruLenPor-ESP32"):
        if sys.platform != "linux":
            raise RuntimeError("HIL_BLUEZ_REQUIRES_LINUX")
        import dbus
        from dbus.mainloop.glib import DBusGMainLoop
        from gi.repository import GLib

        DBusGMainLoop(set_as_default=True)
        self.dbus, self.GLib = dbus, GLib
        self.bus = dbus.SystemBus()
        self.manager = dbus.Interface(self.bus.get_object(BLUEZ, "/"), OBJECT_MANAGER)
        self.adapter_path = f"/org/bluez/{adapter}"
        self.adapter = dbus.Interface(self.bus.get_object(BLUEZ, self.adapter_path), ADAPTER)
        self.name = name
        self.device_path = None
        self.tx = self.rx = None
        self.signal = None
        self.lines = deque(maxlen=1024)
        self.frames = deque()
        self.buffer = bytearray()
        self.notifications = 0
        self.max_notification_bytes = 0
        self.completed_frames = 0
        self.protocol_errors = 0
        # ESP32-CAM info discovered during BLE setup
        self.esp_mac = None
        self.esp_hostname = None
        self.paired = False

    def properties(self, path: str, interface: str) -> dict:
        obj = self.bus.get_object(BLUEZ, path)
        return self.dbus.Interface(obj, PROPERTIES).GetAll(interface)

    def pump(self, seconds: float = 0.0) -> None:
        deadline = time.monotonic() + seconds
        context = self.GLib.MainContext.default()
        while True:
            for _ in range(500):
                if not context.pending():
                    break
                context.iteration(False)
            if time.monotonic() >= deadline:
                return
            time.sleep(POLL_SECONDS)

    def wait(self, predicate, timeout: float, code: str):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.pump()
            result = predicate()
            if result:
                return result
            time.sleep(POLL_SECONDS)
        raise TimeoutError(code)

    def discover(self, timeout: float = 15) -> dict:
        powered = self.properties(self.adapter_path, ADAPTER).get("Powered")
        require(bool(powered), "HIL_BLUETOOTH_POWERED_OFF")
        self.adapter.SetDiscoveryFilter(self.dbus.Dictionary({
            "Transport": "le",
            "UUIDs": self.dbus.Array([SERVICE_UUID], signature="s"),
            "DuplicateData": True,
        }, signature="sv"))
        self.adapter.StartDiscovery()
        try:
            def find():
                for path, interfaces in self.manager.GetManagedObjects().items():
                    device = interfaces.get(DEVICE)
                    if device and str(path).startswith(self.adapter_path + "/"):
                        uuids = [str(value).lower() for value in device.get("UUIDs", [])]
                        if device.get("Name") == self.name and SERVICE_UUID in uuids:
                            self.device_path = str(path)
                            return {"name": str(device["Name"]), "service_uuid": SERVICE_UUID}
                return None

            return self.wait(find, timeout, "HIL_BLE_ADVERTISEMENT_NOT_FOUND")
        finally:
            self.adapter.StopDiscovery()

    def assert_not_advertising(self, seconds: float) -> None:
        """Discard only this fixture's cached entry before checking fresh scans."""
        if self.device_path is not None:
            device = self.manager.GetManagedObjects().get(self.device_path, {}).get(DEVICE)
            if device is not None:
                require(not device.get("Connected", False), "HIL_BLE_STILL_CONNECTED")
                try:
                    self.adapter.RemoveDevice(self.device_path)
                except self.dbus.DBusException as exc:
                    if not self._device_disappeared(exc):
                        raise
            self.device_path = None
        self.adapter.SetDiscoveryFilter(self.dbus.Dictionary({
            "Transport": "le",
            "UUIDs": self.dbus.Array([SERVICE_UUID], signature="s"),
            "DuplicateData": True,
        }, signature="sv"))
        self.adapter.StartDiscovery()
        try:
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                self.pump()
                for path, interfaces in self.manager.GetManagedObjects().items():
                    device = interfaces.get(DEVICE, {})
                    if str(path).startswith(self.adapter_path + "/") and device.get("Name") == self.name:
                        require(SERVICE_UUID not in [str(value).lower() for value in device.get("UUIDs", [])],
                                "HIL_BLE_ADVERTISING_IN_WIFI_MODE")
                time.sleep(POLL_SECONDS)
        finally:
            self.adapter.StopDiscovery()

    def connect(self) -> dict:
        if self.device_path is None:
            self.discover()
        device = self.dbus.Interface(self.bus.get_object(BLUEZ, self.device_path), DEVICE)
        if not self.properties(self.device_path, DEVICE).get("Connected", False):
            device.Connect(timeout=20)
        if not self.properties(self.device_path, DEVICE).get("Connected", False):
            raise TimeoutError("HIL_BLE_CONNECT_TIMEOUT")
        self.wait(lambda: self.properties(self.device_path, DEVICE).get("ServicesResolved"),
                  20, "HIL_GATT_DISCOVERY_TIMEOUT")
        objects = self.manager.GetManagedObjects()
        service_path = next((str(p) for p, i in objects.items()
                             if str(p).startswith(self.device_path + "/")
                             and i.get(SERVICE, {}).get("UUID") == SERVICE_UUID), None)
        require(service_path is not None, "HIL_SERVICE_MISSING")
        paths = {}
        flags = {}
        for path, interfaces in objects.items():
            characteristic = interfaces.get(CHARACTERISTIC)
            if characteristic and characteristic.get("Service") == service_path:
                uuid = str(characteristic["UUID"])
                paths[uuid] = str(path)
                flags[uuid] = [str(flag) for flag in characteristic["Flags"]]
        require(TX_UUID in paths and RX_UUID in paths, "HIL_CHARACTERISTIC_MISSING")
        require("notify" in flags[TX_UUID] and "write" in flags[RX_UUID], "HIL_GATT_FLAGS")
        require(any(i.get(DESCRIPTOR, {}).get("UUID") == CCCD_UUID
                    and i.get(DESCRIPTOR, {}).get("Characteristic") == paths[TX_UUID]
                    for i in objects.values()), "HIL_CCCD_MISSING")
        if self.signal is not None:
            self.signal.remove()
        self.buffer.clear()
        self.frames.clear()
        self.lines.clear()
        self.esp_mac = None
        self.esp_hostname = None
        self.paired = False
        self.signal = self.bus.add_signal_receiver(
            self._notification, dbus_interface=PROPERTIES,
            signal_name="PropertiesChanged", arg0=CHARACTERISTIC, path=paths[TX_UUID]
        )
        self.tx = self.dbus.Interface(self.bus.get_object(BLUEZ, paths[TX_UUID]), CHARACTERISTIC)
        self.rx = self.dbus.Interface(self.bus.get_object(BLUEZ, paths[RX_UUID]), CHARACTERISTIC)
        self.subscribe(True)
        self.pump(0.2)
        return {"tx_flags": flags[TX_UUID], "rx_flags": flags[RX_UUID], "cccd": True}

    def subscribe(self, enabled: bool) -> None:
        (self.tx.StartNotify if enabled else self.tx.StopNotify)(timeout=10)
        self.pump(0.1)

    def _notification(self, interface, changed, invalidated) -> None:
        del interface, invalidated
        if "Value" not in changed:
            return
        data = bytes(changed["Value"])
        self.notifications += 1
        self.max_notification_bytes = max(self.max_notification_bytes, len(data))
        self.buffer.extend(data)
        while self.buffer:
            if self.buffer.startswith(b"\xff\xd8"):
                end = self.buffer.find(b"\xff\xd9", 2)
                if end < 0:
                    if len(self.buffer) > MAX_FRAME_BYTES:
                        self.protocol_errors += 1
                        self.buffer.clear()
                    return
                frame = bytes(self.buffer[:end + 2])
                del self.buffer[:end + 2]
                self.frames.append((time.monotonic(), frame))
                self.completed_frames += 1
            elif self.buffer.startswith(b"$"):
                end = self.buffer.find(b"\n")
                if end < 0:
                    if len(self.buffer) > MAX_TEXT_BYTES:
                        self.protocol_errors += 1
                        self.buffer.clear()
                    return
                line = bytes(self.buffer[:end]).decode("utf-8", errors="replace").rstrip("\r")
                del self.buffer[:end + 1]
                self.lines.append((time.monotonic(), line))
                # Parse ESP MAC and hostname from BLE notifications
                if line.startswith("$ESP_MAC:"):
                    self.esp_mac = line[len("$ESP_MAC:"):]
                elif line.startswith("$ESP_NAME:"):
                    self.esp_hostname = line[len("$ESP_NAME:"):]
                elif line == "$CMD:paired":
                    self.paired = True
            else:
                starts = [position for position in (self.buffer.find(b"$"), self.buffer.find(b"\xff\xd8"))
                          if position >= 0]
                if starts:
                    del self.buffer[:min(starts)]
                elif self.buffer[-1] == 0xFF:
                    self.buffer[:] = b"\xff"
                    return
                else:
                    self.buffer.clear()

    def write(self, data: bytes) -> None:
        self.rx.WriteValue(self.dbus.Array(data, signature="y"),
                           self.dbus.Dictionary({"type": "request"}, signature="sv"), timeout=15)

    def line(self, prefix: str, since: float, timeout: float = 8) -> str:
        prefix = prefix.rstrip("\r\n")
        def take():
            for index, (stamp, text) in enumerate(self.lines):
                if stamp >= since and (text == prefix if prefix.startswith("$CMD:")
                                       else text.startswith(prefix)):
                    del self.lines[index]
                    return text
            return None

        return self.wait(take, timeout, "HIL_REPLY_TIMEOUT")

    def command(self, code: int, ack: str | None = None) -> str | None:
        since = time.monotonic()
        self.write(bytes([code]))
        return self.line(ack, since) if ack else None

    def pair(self, code: str = BLE_PAIRING_CODE, timeout: float = 10) -> bool:
        """Send pairing code to ESP over BLE. Returns True when paired."""
        since = time.monotonic()
        self.write(bytes([CMD_BLE_PAIR]) + code.encode())
        self.line("$CMD:paired", since, timeout)
        self.paired = True
        return True

    def wifi_config_put(self, ssid: str, password: str, timeout: float = 10) -> int:
        """Send WiFi credentials to ESP over BLE. Returns payload length."""
        payload = bytes([CMD_WIFI_CONFIG_PUT]) + ssid.encode() + b"\0" + password.encode() + b"\0"
        since = time.monotonic()
        self.write(payload)
        self.line("$CMD:wifi_config_received", since, timeout)
        return len(payload)

    def reboot(self, timeout: float = 10) -> bool:
        """Send reboot command to ESP over BLE."""
        since = time.monotonic()
        self.write(bytes([CMD_REBOOT]))
        self.line("$CMD:reboot", since, timeout)
        return True

    def wifi_erase(self, timeout: float = 10) -> bool:
        """Erase WiFi credentials from ESP NVS so it reboots in BLE-first mode."""
        since = time.monotonic()
        self.write(bytes([CMD_WIFI_CONFIG_PUT]) + b"\0\0")
        self.line("$CMD:wifi_config_received", since, timeout)
        return True

    def status(self) -> dict[str, str]:
        since = time.monotonic()
        self.write(b"\x09")
        text = self.line("$STATUS:", since)
        return dict(pair.split("=", 1) for pair in text.removeprefix("$STATUS:").split(","))

    def frame(self, timeout: float = 10) -> tuple[float, bytes]:
        return self.wait(lambda: self.frames.popleft() if self.frames else None,
                         timeout, "HIL_BLE_FRAME_TIMEOUT")

    def clear_frames(self) -> None:
        self.pump(0.2)
        self.frames.clear()

    def disconnect(self) -> None:
        try:
            if self.device_path is not None:
                interfaces = self.manager.GetManagedObjects().get(self.device_path, {})
                if DEVICE not in interfaces:
                    self.device_path = None
                elif interfaces[DEVICE].get("Connected", False):
                    try:
                        device = self.dbus.Interface(self.bus.get_object(BLUEZ, self.device_path), DEVICE)
                        device.Disconnect(timeout=10)
                    except self.dbus.DBusException as exc:
                        if not self._device_disappeared(exc):
                            raise
                        self.device_path = None
                self.pump(0.2)
        finally:
            if self.signal is not None:
                self.signal.remove()
                self.signal = None
            self.buffer.clear()
            self.frames.clear()
            self.lines.clear()
            self.tx = self.rx = None
            self.paired = False

    def _device_disappeared(self, error) -> bool:
        """Accept only an absent-object race, not an adapter or transport failure."""
        return error.get_dbus_name() in (
            "org.freedesktop.DBus.Error.UnknownObject",
            "org.freedesktop.DBus.Error.UnknownMethod",
            "org.bluez.Error.DoesNotExist",
        ) and self.device_path not in self.manager.GetManagedObjects()


class UdpFrames:
    def __init__(self, ip: str, port: int = UDP_PORT):
        address = ipaddress.IPv4Address(ip)
        require(not address.is_unspecified and not address.is_multicast and not address.is_loopback,
                "HIL_UDP_INVALID_PEER")
        self.peer = (ip, port)
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.bind(("0.0.0.0", 0))
        try:
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 262144)
        except OSError:
            pass
        self.socket.setblocking(False)
        self.parts = {}
        self.parity = {}
        self.total = 0
        self.frame_size = 0
        self.frame_id = None
        self.last_frame_id = None
        self.dropped_frames = 0
        self.stale_datagrams = 0
        self.packets = 0
        self.parity_packets = 0
        self.datagrams = 0
        self.control_messages = []
        self.last_control_echo_seen = False
        self.background_video_datagrams = 0

    @staticmethod
    def _newer_frame(candidate: int, reference: int) -> bool:
        difference = (candidate - reference) & 0xFFFFFFFF
        return difference != 0 and difference < 0x80000000

    @staticmethod
    def _is_video_datagram(packet: bytes) -> bool:
        if len(packet) < UDP_HEADER.size:
            return False
        raw_seq, total, offset, size, _frame_id, frame_size = UDP_HEADER.unpack_from(packet)
        is_parity = bool(raw_seq & UDP_PARITY_SEQUENCE_FLAG)
        sequence = raw_seq & 0x7FFFFFFF
        if not (0 < total <= (MAX_FRAME_BYTES + UDP_PAYLOAD_BYTES - 1) // UDP_PAYLOAD_BYTES):
            return False
        if not (4 <= frame_size <= MAX_FRAME_BYTES):
            return False
        if total != (frame_size + UDP_PAYLOAD_BYTES - 1) // UDP_PAYLOAD_BYTES:
            return False
        if not (0 < size <= UDP_PAYLOAD_BYTES and len(packet) == UDP_HEADER.size + size):
            return False
        if is_parity:
            groups = min(total, UDP_FEC_GROUP_SIZE)
            group_start = sequence
            return (sequence < groups and offset == group_start * UDP_PAYLOAD_BYTES
                    and size == UDP_PAYLOAD_BYTES and offset < frame_size)
        return (sequence < total and offset == sequence * UDP_PAYLOAD_BYTES
                and size == min(UDP_PAYLOAD_BYTES, frame_size - offset))

    def _clear_frame(self):
        self.parts.clear()
        self.parity.clear()
        self.total = 0
        self.frame_size = 0
        self.frame_id = None

    def _recover(self):
        group_count = min(self.total, UDP_FEC_GROUP_SIZE)
        for group_index in range(group_count):
            members = range(group_index, self.total, UDP_FEC_GROUP_SIZE)
            missing = [seq for seq in members if seq not in self.parts]
            if len(missing) != 1 or group_index not in self.parity:
                continue
            recovered = bytearray(self.parity[group_index])
            for seq in range(group_index, self.total, UDP_FEC_GROUP_SIZE):
                if seq == missing[0]:
                    continue
                part = self.parts.get(seq)
                if part is None:
                    continue
                for index, value in enumerate(part):
                    recovered[index] ^= value
            offset = missing[0] * UDP_PAYLOAD_BYTES
            expected = min(UDP_PAYLOAD_BYTES, self.frame_size - offset)
            self.parts[missing[0]] = bytes(recovered[:expected])

    def command(self, data: bytes) -> None:
        self.socket.sendto(data, self.peer)

    def wait_echo(self, expected: bytes, timeout: float = 10) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                packet, source = self.socket.recvfrom(UDP_RECEIVE_BYTES)
            except BlockingIOError:
                time.sleep(POLL_SECONDS)
                continue
            self.datagrams += 1
            require(source == self.peer, "HIL_UDP_SOURCE")
            require(packet == expected, "HIL_UDP_ECHO_MISMATCH")
            return
        raise TimeoutError("HIL_UDP_ECHO_TIMEOUT")

    def request_control(
        self,
        command: bytes,
        prefix: str,
        timeout: float = 4,
        attempts: int = 3,
        echo: bytes | None = None,
        required_status_copies: int = 2,
    ) -> str:
        require(
            bool(command) and attempts >= 1 and required_status_copies in (1, 2),
            "HIL_UDP_CONTROL_ARGUMENT",
        )
        expected = prefix.encode("ascii")
        echo_seen = False
        response = None
        for _ in range(attempts):
            if response is None or (echo is not None and not echo_seen):
                self.command(command)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    packet, source = self.socket.recvfrom(UDP_RECEIVE_BYTES)
                except BlockingIOError:
                    time.sleep(POLL_SECONDS)
                    continue
                self.datagrams += 1
                require(source == self.peer, "HIL_UDP_SOURCE")
                if len(command) == 1 and packet == command:
                    # The ESP may return the same one-byte packet as an ARP
                    # warm-up. Flutter ignores it and waits for the text ACK.
                    echo_seen = True
                    if echo is not None and response is not None:
                        self.last_control_echo_seen = True
                        return response
                    continue
                if echo is not None and packet == echo:
                    echo_seen = True
                    if response is not None:
                        self.last_control_echo_seen = True
                        return response
                    continue
                if packet.startswith(expected):
                    response = packet.decode("utf-8", errors="replace").rstrip("\r\n")
                    if echo is None or echo_seen:
                        if prefix == "$STATUS:" and echo is None:
                            # Status replies are duplicated by the ESP. A prior
                            # duplicate may be queued before this request, so
                            # require the pair and return the second snapshot.
                            # This skips at most one stale response and avoids a
                            # long quiet-window that would starve live video.
                            status_copies = 1
                            duplicate_deadline = time.monotonic() + 0.15
                            while (
                                status_copies < required_status_copies
                                and time.monotonic() < duplicate_deadline
                            ):
                                try:
                                    duplicate, duplicate_source = self.socket.recvfrom(UDP_RECEIVE_BYTES)
                                except BlockingIOError:
                                    time.sleep(POLL_SECONDS)
                                    continue
                                self.datagrams += 1
                                require(duplicate_source == self.peer, "HIL_UDP_SOURCE")
                                if duplicate.startswith(expected):
                                    response = duplicate.decode(
                                        "utf-8", errors="replace"
                                    ).rstrip("\r\n")
                                    status_copies += 1
                                    continue
                                if duplicate.startswith(b"$ERROR:"):
                                    raise AssertionError("HIL_UDP_COMMAND_ERROR")
                                if duplicate.startswith(b"$CMD:"):
                                    message = duplicate.decode(
                                        "utf-8", errors="replace"
                                    ).rstrip("\r\n")
                                    require(message in {
                                        "$CMD:stream_on", "$CMD:stream_off",
                                        "$CMD:single_frame", "$CMD:keepalive",
                                        "$CMD:flash_on", "$CMD:flash_off",
                                        "$CMD:restart", "$CMD:shutdown_complete",
                                    }, "HIL_UDP_UNKNOWN_ACK")
                                    self.control_messages.append(message)
                                    continue
                                if self._is_video_datagram(duplicate):
                                    self.background_video_datagrams += 1
                                    continue
                                if len(duplicate) < UDP_HEADER.size:
                                    continue
                                raise AssertionError("HIL_UDP_UNEXPECTED_CONTROL")
                        self.last_control_echo_seen = echo_seen
                        return response
                    continue
                if packet.startswith(b"$ERROR:"):
                    raise AssertionError("HIL_UDP_COMMAND_ERROR")
                if packet.startswith(b"$CMD:"):
                    message = packet.decode("utf-8", errors="replace").rstrip("\r\n")
                    allowed = {
                        "$CMD:stream_on",
                        "$CMD:stream_off",
                        "$CMD:single_frame",
                        "$CMD:keepalive",
                        "$CMD:flash_on",
                        "$CMD:flash_off",
                        "$CMD:restart",
                        "$CMD:shutdown_complete",
                    }
                    require(message in allowed, "HIL_UDP_UNKNOWN_ACK")
                    self.control_messages.append(message)
                    continue
                if self._is_video_datagram(packet):
                    # Video and control share the app's UDP socket. Frames can
                    # arrive while the HIL awaits a status/command response.
                    self.background_video_datagrams += 1
                    continue
                raise AssertionError("HIL_UDP_UNEXPECTED_CONTROL")
        if echo is not None and not echo_seen:
            raise AssertionError("HIL_UDP_PEER_ECHO_MISSING")
        raise TimeoutError("HIL_UDP_CONTROL_TIMEOUT")

    def control_line(self, prefix: str, timeout: float = 10) -> str:
        expected = prefix.encode("ascii")
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                packet, source = self.socket.recvfrom(UDP_RECEIVE_BYTES)
            except BlockingIOError:
                time.sleep(POLL_SECONDS)
                continue
            self.datagrams += 1
            require(source == self.peer, "HIL_UDP_SOURCE")
            if packet.startswith(expected):
                return packet.decode("utf-8", errors="replace").rstrip("\r\n")
            raise AssertionError("HIL_UDP_UNEXPECTED_CONTROL")
        raise TimeoutError("HIL_UDP_CONTROL_TIMEOUT")

    def next_frame(self, client: BluezClient | None = None, timeout: float = 10) -> tuple[float, bytes]:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if client is not None:
                client.pump()
            try:
                packet, source = self.socket.recvfrom(UDP_RECEIVE_BYTES)
            except BlockingIOError:
                time.sleep(POLL_SECONDS)
                continue
            self.datagrams += 1
            require(source == self.peer, "HIL_UDP_SOURCE")
            if packet.startswith(b"$CMD:"):
                message = packet.decode("utf-8", errors="replace").rstrip("\r\n")
                allowed = {
                    "$CMD:stream_on",
                    "$CMD:stream_off",
                    "$CMD:single_frame",
                    "$CMD:keepalive",
                    "$CMD:flash_on",
                    "$CMD:flash_off",
                    "$CMD:restart",
                    "$CMD:shutdown_complete",
                }
                require(message in allowed, "HIL_UDP_UNKNOWN_ACK")
                self.control_messages.append(message)
                continue
            if packet.startswith(b"$STATUS:"):
                # ESP may duplicate idempotent status replies for RF resilience.
                # They are control-plane text, never a V2 video packet.
                self.control_messages.append(
                    packet.decode("utf-8", errors="replace").rstrip("\\r\\n")
                )
                continue
            if packet.startswith(b"$ERROR:"):
                raise AssertionError("HIL_UDP_COMMAND_ERROR")
            if len(packet) < UDP_HEADER.size:
                # Match the app receiver: transport echoes and all other short
                # datagrams are ignored, never interpreted as V2 frame headers.
                continue

            raw_seq, total, offset, size, frame_id, frame_size = UDP_HEADER.unpack_from(packet)
            is_parity = bool(raw_seq & UDP_PARITY_SEQUENCE_FLAG)
            sequence = raw_seq & 0x7FFFFFFF
            max_parts = (MAX_FRAME_BYTES + UDP_PAYLOAD_BYTES - 1) // UDP_PAYLOAD_BYTES
            require(0 < total <= max_parts and 4 <= frame_size <= MAX_FRAME_BYTES
                    and total == (frame_size + UDP_PAYLOAD_BYTES - 1) // UDP_PAYLOAD_BYTES,
                    "HIL_UDP_SEQUENCE")
            require(0 < size <= UDP_PAYLOAD_BYTES and len(packet) == UDP_HEADER.size + size,
                    "HIL_UDP_SIZE")
            if is_parity:
                group_count = min(total, UDP_FEC_GROUP_SIZE)
                group_start = sequence
                require(sequence < group_count and offset == group_start * UDP_PAYLOAD_BYTES
                        and size == UDP_PAYLOAD_BYTES and offset < frame_size,
                        "HIL_UDP_PARITY")
            else:
                expected_offset = sequence * UDP_PAYLOAD_BYTES
                expected_size = min(UDP_PAYLOAD_BYTES, frame_size - expected_offset)
                require(sequence < total and offset == expected_offset
                        and size == expected_size, "HIL_UDP_OFFSET")

            if self.frame_id is None:
                if self.last_frame_id is not None and not self._newer_frame(frame_id, self.last_frame_id):
                    self.stale_datagrams += 1
                    continue
                self.frame_id, self.last_frame_id = frame_id, frame_id
                self.total, self.frame_size = total, frame_size
            elif frame_id != self.frame_id:
                if not self._newer_frame(frame_id, self.frame_id):
                    self.stale_datagrams += 1
                    continue
                if self.parts:
                    self.dropped_frames += 1
                self._clear_frame()
                self.frame_id, self.last_frame_id = frame_id, frame_id
                self.total, self.frame_size = total, frame_size
            elif total != self.total or frame_size != self.frame_size:
                self._clear_frame()
                continue

            payload = packet[UDP_HEADER.size:]
            table = self.parity if is_parity else self.parts
            existing = table.get(sequence)
            if existing is not None:
                require(existing == payload, "HIL_UDP_DUPLICATE_CONFLICT")
                continue
            table[sequence] = payload
            if is_parity:
                self.parity_packets += 1
            else:
                self.packets += 1

            self._recover()
            if len(self.parts) == self.total:
                frame = b"".join(self.parts[index] for index in range(self.total))
                require(len(frame) == self.frame_size, "HIL_UDP_FRAME_SIZE")
                self._clear_frame()
                return time.monotonic(), frame
        raise TimeoutError("HIL_UDP_FRAME_TIMEOUT")

    def drain(self) -> None:
        while True:
            try:
                self.socket.recvfrom(UDP_RECEIVE_BYTES)
            except BlockingIOError:
                break
        # Preserve the last completed frame watermark. Late data/parity packets
        # from that frame can still arrive after the socket queue was drained;
        # the Flutter receiver rejects them using the same frame-ID watermark.
        self._clear_frame()

    def close(self) -> None:
        self.socket.close()
