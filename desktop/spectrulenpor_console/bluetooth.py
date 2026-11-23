"BlueZ GATT client built on the system D-Bus API."
from __future__ import annotations
import threading, time
from collections import deque
from dataclasses import dataclass
from typing import Callable
import gi
gi.require_version("Gio", "2.0")
from gi.repository import Gio, GLib
from .protocol import *

BLUEZ = "org.bluez"
OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
PROPERTIES = "org.freedesktop.DBus.Properties"
ADAPTER = "org.bluez.Adapter1"
DEVICE = "org.bluez.Device1"
GATT_SERVICE = "org.bluez.GattService1"
GATT_CHARACTERISTIC = "org.bluez.GattCharacteristic1"

@dataclass(frozen=True, slots=True)
class BleDevice:
    path: str
    name: str
    address: str
    rssi: int | None
    connected: bool

class BluezClient:
    """Run blocking GATT calls in a worker; notifications arrive on GLib main loop."""
    def __init__(self, adapter: str = "hci0"):
        self.adapter_path = f"/org/bluez/{adapter}"
        self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.device_path = self.service_path = self.tx_path = self.rx_path = None
        self._signal_id = 0
        self._lock = threading.Condition()
        self._line_buffer = bytearray()
        self._lines: deque[str] = deque(maxlen=512)
        self._notify_bytes = 0
        self._on_line: Callable[[str], None] | None = None
        self._discovering = self._notify_subscribed = self.paired = False
        self.mac = self.hostname = None

    def set_line_callback(self, callback):
        self._on_line = callback

    def _call(self, path, interface, method, parameters=None, timeout_ms=15000):
        return self.bus.call_sync(BLUEZ, path, interface, method, parameters, None,
            Gio.DBusCallFlags.NONE, timeout_ms, None)

    def _properties(self, path, interface):
        return self._call(path, PROPERTIES, "GetAll", GLib.Variant("(s)", (interface,))).unpack()[0]

    def _objects(self):
        return self._call("/", OBJECT_MANAGER, "GetManagedObjects").unpack()[0]

    def _set_adapter_powered(self):
        if not self._properties(self.adapter_path, ADAPTER).get("Powered", False):
            self._call(self.adapter_path, PROPERTIES, "Set", GLib.Variant("(ssv)",
                (ADAPTER, "Powered", GLib.Variant("b", True))))
            time.sleep(0.5)

    def scan(self, timeout=10.0):
        self._set_adapter_powered()
        filt = {"Transport": GLib.Variant("s", "le"),
                "UUIDs": GLib.Variant("as", [BLE_SERVICE_UUID]),
                "DuplicateData": GLib.Variant("b", True)}
        self._call(self.adapter_path, ADAPTER, "SetDiscoveryFilter", GLib.Variant("(a{sv})", (filt,)))
        try:
            self._call(self.adapter_path, ADAPTER, "StartDiscovery", timeout_ms=5000)
            self._discovering = True
        except Exception as exc:
            if "inprogress" not in str(exc).lower() and "already discovering" not in str(exc).lower():
                raise RuntimeError(f"Bluetooth scan could not start: {exc}") from exc
        found = {}
        deadline = time.monotonic() + timeout
        try:
            while time.monotonic() < deadline:
                for path, interfaces in self._objects().items():
                    props = interfaces.get(DEVICE)
                    if not props or not str(path).startswith(self.adapter_path + "/"): continue
                    uuids = {str(item).lower() for item in props.get("UUIDs", [])}
                    name = str(props.get("Name") or props.get("Alias") or "")
                    if BLE_SERVICE_UUID not in uuids and "spectrulenpor" not in name.lower(): continue
                    rssi = props.get("RSSI")
                    found[str(path)] = BleDevice(str(path), name or BLE_DEVICE_NAME,
                        str(props.get("Address", "")), int(rssi) if rssi is not None else None,
                        bool(props.get("Connected", False)))
                time.sleep(0.2)
        finally:
            if self._discovering:
                try: self._call(self.adapter_path, ADAPTER, "StopDiscovery", timeout_ms=5000)
                except Exception: pass
                self._discovering = False
        return sorted(found.values(), key=lambda d: d.rssi if d.rssi is not None else -127, reverse=True)

    def connect(self, device_path, timeout=20.0):
        self._set_adapter_powered()
        self.device_path = device_path
        if not self._properties(device_path, DEVICE).get("Connected", False):
            self._call(device_path, DEVICE, "Connect", timeout_ms=int(timeout * 1000))
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            objects = self._objects()
            service_path = None
            for path, interfaces in objects.items():
                service = interfaces.get(GATT_SERVICE)
                if service and service.get("Device") == device_path and str(service.get("UUID", "")).lower() == BLE_SERVICE_UUID:
                    service_path = str(path); break
            if service_path:
                tx = rx = None
                for path, interfaces in objects.items():
                    char = interfaces.get(GATT_CHARACTERISTIC)
                    if not char or str(char.get("Service")) != service_path: continue
                    uuid = str(char.get("UUID", "")).lower()
                    if uuid == BLE_TX_UUID: tx = str(path)
                    elif uuid == BLE_RX_UUID: rx = str(path)
                if tx and rx:
                    self.service_path, self.tx_path, self.rx_path = service_path, tx, rx
                    break
            time.sleep(0.25)
        if not self.tx_path or not self.rx_path:
            raise TimeoutError("ESP32 connected, but FFE0/FFE1/FFE2 GATT characteristics did not appear")
        self._subscribe_notifications()

    def _subscribe_notifications(self):
        if self._signal_id: self.bus.signal_unsubscribe(self._signal_id)
        self._signal_id = self.bus.signal_subscribe(None, PROPERTIES, "PropertiesChanged",
            self.tx_path, GATT_CHARACTERISTIC, Gio.DBusSignalFlags.NONE, self._properties_changed, None)
        self._call(self.tx_path, GATT_CHARACTERISTIC, "StartNotify", timeout_ms=10000)
        self._notify_subscribed = True

    def _properties_changed(self, _conn, _sender, _path, _iface, _signal, params, _data):
        try:
            interface, changed, _invalidated = params.unpack()
            if interface != GATT_CHARACTERISTIC or "Value" not in changed: return
            data = bytes(changed["Value"])
        except Exception: return
        if not data: return
        emitted = []
        with self._lock:
            self._notify_bytes += len(data); self._line_buffer.extend(data)
            while b"\n" in self._line_buffer:
                raw, _, rest = self._line_buffer.partition(b"\n"); self._line_buffer = bytearray(rest)
                line = raw.decode("utf-8", errors="replace").strip("\r\x00 ")
                if not line: continue
                self._lines.append(line); emitted.append(line)
                if line.startswith("$ESP_MAC:"): self.mac = line.split(":", 1)[1].strip()
                if line.startswith("$ESP_NAME:"): self.hostname = line.split(":", 1)[1].strip()
            self._lock.notify_all()
        if self._on_line:
            for line in emitted: self._on_line(line)

    def write(self, data: bytes):
        if not self.rx_path: raise RuntimeError("BLE is not connected")
        self._call(self.rx_path, GATT_CHARACTERISTIC, "WriteValue",
            GLib.Variant("(aya{sv})", (list(data), {})), timeout_ms=10000)

    def _clear_lines(self):
        with self._lock:
            self._lines.clear()
            self._line_buffer.clear()

    def wait_line(self, predicate, timeout=10.0):
        deadline = time.monotonic() + timeout
        with self._lock:
            while True:
                for line in reversed(self._lines):
                    if predicate(line): return line
                remaining = deadline - time.monotonic()
                if remaining <= 0: raise TimeoutError("Timed out waiting for ESP32 BLE acknowledgement")
                self._lock.wait(min(remaining, 0.25))

    def pair(self, code=BLE_PAIRING_CODE):
        if code != BLE_PAIRING_CODE: raise ValueError("Firmware pairing code is 11111")
        self._clear_lines()
        self.write(bytes([CMD_BLE_PAIR]) + code.encode("ascii"))
        result = self.wait_line(lambda x: x == "$CMD:paired", 10)
        self.paired = True
        return result

    def provision_wifi(self, ssid, password):
        if not self.paired: raise RuntimeError("Pair with the device before Wi-Fi provisioning")
        self._clear_lines()
        before = self.notification_bytes
        self.write(encode_wifi_credentials(ssid, password))
        self.wait_line(lambda x: x == "$CMD:wifi_config_received", 15)
        identity = []
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            with self._lock:
                identity = [x for x in self._lines if x.startswith(("$ESP_MAC:", "$ESP_NAME:"))]
                if any(x.startswith("$ESP_MAC:") for x in identity) and any(x.startswith("$ESP_NAME:") for x in identity): break
                self._lock.wait(0.15)
        if not identity: identity = [f"$BLE_NOTIFY_BYTES:{self.notification_bytes - before}"]
        return list(dict.fromkeys(identity))

    def request_status(self, timeout=5.0):
        self._clear_lines()
        self.write(bytes([CMD_CONNECTION_STATUS]))
        return self.wait_line(lambda x: x.startswith("$STATUS:"), timeout)

    def request_wifi_config(self, timeout=5.0):
        self._clear_lines()
        self.write(bytes([CMD_WIFI_CONFIG_GET]))
        return self.wait_line(lambda x: x.startswith("$WIFI_CFG:"), timeout)

    def reboot(self, timeout=6.0):
        self._clear_lines()
        self.write(bytes([CMD_REBOOT]))
        return self.wait_line(lambda x: x == "$CMD:reboot", timeout)

    def disconnect(self):
        if self.tx_path and self._notify_subscribed:
            try: self._call(self.tx_path, GATT_CHARACTERISTIC, "StopNotify", timeout_ms=3000)
            except Exception: pass
        self._notify_subscribed = False
        if self._signal_id:
            self.bus.signal_unsubscribe(self._signal_id); self._signal_id = 0
        if self.device_path:
            try: self._call(self.device_path, DEVICE, "Disconnect", timeout_ms=5000)
            except Exception: pass
        self.device_path = self.service_path = self.tx_path = self.rx_path = None
        self.paired = False

    @property
    def notification_bytes(self):
        with self._lock: return self._notify_bytes
