#!/usr/bin/env python3
"""Exercise BLE, JPEG capture, WiFi/UDP and recovery on an ESP32-CAM on Linux."""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

FIRMWARE_ROOT = Path(__file__).resolve().parents[1]
if str(FIRMWARE_ROOT) not in sys.path:
    sys.path.insert(0, str(FIRMWARE_ROOT))

from testbench.errors import TestbenchError
from testbench.hardware_lock import HardwareLock
from testbench.settings import DEFAULT_ADAPTER
from standalone_signals import StandaloneSignals, StandaloneInterrupted

from hardware_helpers import (BluezClient, UARTLog, UdpFrames, decode_jpeg, require, is_gatt_rejection,
                              BLE_PAIRING_CODE, CMD_STREAM_ON, CMD_STREAM_OFF,
                              CMD_SINGLE_FRAME, CMD_FLASH_ON, CMD_FLASH_OFF,
                              CMD_RESTART, CMD_SHUTDOWN, CMD_WIFI_CONFIG_PUT,
                              CMD_BLE_PAIR, CMD_REBOOT, CMD_CONNECTION_STATUS, CMD_UDP_KEEPALIVE)

REPLY_TIMEOUT = 8
WIFI_TIMEOUT = 120
IDLE_SECONDS = 2.2
UDP_TEST_FRAMES = 30
BLE_SCAN_SECONDS = 5
BLE_FRAME_SIZE = (320, 240)
UDP_FRAME_SIZES = frozenset({(1024, 768), (800, 600), (640, 480), (320, 240)})
MAX_SSID_BYTES = 32
MAX_PASSWORD_BYTES = 64
TEST_PASSWORD = "TestPass123"
NMCLI_TIMEOUT_SECONDS = 20


def network_manager_credentials(interruption=None) -> tuple[str, str]:
    """Read the active WiFi profile into memory; never print or save its PSK."""
    executable = shutil.which("nmcli")
    if executable is None:
        raise RuntimeError("HIL_NMCLI_MISSING")

    def run(*arguments):
        command = [executable, "--escape", "no", *arguments]
        if interruption is not None:
            return interruption.command_output(command, NMCLI_TIMEOUT_SECONDS).rstrip("\n")
        result = subprocess.run(command, capture_output=True, text=True, timeout=NMCLI_TIMEOUT_SECONDS)
        if result.returncode != 0:
            raise RuntimeError("HIL_WIFI_PROFILE_UNAVAILABLE")
        return result.stdout.rstrip("\n")

    devices = run("-t", "-f", "DEVICE,TYPE,STATE", "device", "status").splitlines()
    device = next((line.split(":")[0] for line in devices
                   if line.split(":")[1:] == ["wifi", "connected"]), None)
    if device is None:
        raise RuntimeError("HIL_ACTIVE_WIFI_MISSING")
    connection = run("-g", "GENERAL.CON-UUID", "device", "show", device)
    ssid = run("-g", "802-11-wireless.ssid", "connection", "show", connection)
    key_management = run("-g", "802-11-wireless-security.key-mgmt", "connection", "show", connection)
    if key_management in ("wpa-eap", "ieee8021x"):
        raise RuntimeError("HIL_PSK_WIFI_REQUIRED")
    password = run("--show-secrets", "-g", "802-11-wireless-security.psk",
                   "connection", "show", connection) if key_management not in ("", "none", "--") else ""
    if password == "--":
        password = ""
    require(bool(ssid), "HIL_WIFI_SSID_MISSING")
    require(len(ssid.encode()) <= 32, "HIL_WIFI_SSID_TOO_LONG")
    require(len(password.encode()) <= 64, "HIL_WIFI_PASSWORD_TOO_LONG")
    return ssid, password


class HardwareSuite:
    def __init__(self, client: BluezClient, output: Path, wifi: tuple[str, str] | None):
        self.client, self.output, self.wifi = client, output, wifi
        self.records = []
        self.images = {}
        self.heap_samples = []
        self.udp = None
        self.wifi_dirty = False
        self.uart = None
        self.phase = "setup"
        self.wifi_recovery_boot = False
        self.cleanup_errors = []
        self.primary_failure = None
        self.interruption = None

    def checkpoint(self):
        if self.interruption is not None:
            self.interruption.checkpoint()

    def receiver(self, ip):
        receiver = UdpFrames(ip)
        if self.interruption is not None:
            self.interruption.bind_udp(receiver)
        return receiver

    def initial_commissioning(self):
        """Wait for BLE setup, either from empty NVS or WiFi-failure recovery."""
        mark = self.uart.reset()
        boot = self.uart.wait(
            r"operation=boot.mode mode=(ble_setup|wifi_only) ble=([01])",
            mark,
            WIFI_TIMEOUT,
            "HIL_BOOT_MODE_MISSING",
        )
        mode, ble_enabled = boot.groups()

        if mode == "ble_setup":
            require(ble_enabled == "1", "HIL_SETUP_BLE_BOOT_MISMATCH")
            self.uart.wait(
                r"operation=ble.advertise",
                mark,
                WIFI_TIMEOUT,
                "HIL_SETUP_ADVERTISEMENT_MISSING",
            )
            return {
                "boot_mode": mode,
                "commissioning_source": "empty_nvs",
                "ble_recovery": False,
            }

        require(ble_enabled == "0", "HIL_WIFI_BOOT_BLE_MISMATCH")
        self.uart.wait(
            r"operation=boot.ready camera=1",
            mark,
            WIFI_TIMEOUT,
            "HIL_CAMERA_BOOT_FAILED",
        )
        transport = self.uart.wait(
            r"operation=wifi.got_ip ip=([0-9.]+)|"
            r"operation=ble.recovery outcome=starting reason=WIFI_UNAVAILABLE",
            mark,
            WIFI_TIMEOUT,
            "HIL_WIFI_OR_BLE_RECOVERY_TIMEOUT",
        )

        if transport.group(1) is not None:
            ip = transport.group(1)
            self.uart.wait(
                r"UDP socket bound on port",
                mark,
                WIFI_TIMEOUT,
                "HIL_UDP_LISTENER_NOT_READY",
            )
            boot_text = self.uart.text(mark)
            require(
                "operation=ble.init" not in boot_text
                and "operation=ble.advertise" not in boot_text,
                "HIL_BLE_STARTED_IN_WIFI_MODE",
            )
            self.phase = "wifi"
            self.udp = self.receiver(ip)
            self.checkpoint()
            # Peer echo is a best-effort ARP warm-up. The app's registration
            # contract is the keepalive acknowledgement, not that optional echo.
            ack = self.udp.request_control(
                bytes([CMD_UDP_KEEPALIVE]), "$CMD:keepalive",
                timeout=2, attempts=4,
            )
            require(ack == "$CMD:keepalive", "HIL_UDP_KEEPALIVE_ACK_MISMATCH")
            status = self.status()
            require(
                status["wifi"] == "connected" and status["ip"] == ip,
                "HIL_WIFI_STATUS_MISMATCH",
            )
            return {
                "boot_mode": mode,
                "commissioning_source": "saved_wifi",
                "ble_recovery": False,
                "wifi": status["wifi"],
                "ip": ip,
                "udp_listener_ready": True,
            }

        self.uart.wait(
            r"operation=ble.recovery outcome=advertising mode=commissioning",
            mark,
            WIFI_TIMEOUT,
            "HIL_BLE_RECOVERY_ADVERTISEMENT_MISSING",
        )
        self.wifi_recovery_boot = True
        return {
            "boot_mode": mode,
            "commissioning_source": "wifi_failure_recovery",
            "ble_recovery": True,
        }

    def local_cleanup(self, operation, *arguments):
        failure = sys.exc_info()[1]
        try:
            if self.interruption is not None:
                with self.interruption.cleanup():
                    operation(*arguments)
            else:
                operation(*arguments)
        except BaseException as error:
            self.cleanup_errors.append(type(error).__name__)
            if failure is None:
                raise RuntimeError("HIL_CLEANUP_INCOMPLETE") from None

    def case(self, name, function):
        started = time.monotonic()
        record = {"name": name}
        try:
            self.checkpoint()
            details = function()
            self.checkpoint()
            require(isinstance(details, dict), "HIL_CASE_MISSING_EVIDENCE")
            record["details"] = details
            record["ok"] = True
        except BaseException as exc:
            if self.primary_failure is None:
                self.primary_failure = exc
            record["ok"] = False
            record["error_type"] = type(exc).__name__
            if isinstance(self.udp, UdpFrames):
                record["transport_evidence"] = {
                    "udp_datagrams": self.udp.datagrams,
                    "accepted_fragments": self.udp.packets,
                    "expected_fragments": self.udp.total,
                    "received_sequences": sorted(self.udp.parts),
                    "incomplete_frames": self.udp.dropped_frames,
                }
            if isinstance(exc, TestbenchError):
                record["code"] = exc.code
            elif isinstance(exc, KeyboardInterrupt):
                record["code"] = "HIL_INTERRUPTED"
            elif isinstance(exc, (AssertionError, RuntimeError, TimeoutError)):
                record["code"] = str(exc)
            elif hasattr(exc, "get_dbus_name"):
                record["code"] = exc.get_dbus_name()
            else:
                record["code"] = "HIL_TEST_FAILED"
            raise
        finally:
            record["seconds"] = round(time.monotonic() - started, 3)
            self.records.append(record)
            print(f'{"PASS" if record.get("ok") else "FAIL"} {name}', flush=True)

    def status(self, udp: UdpFrames | None = None):
        if self.phase == "setup":
            status = self.client.status()
        elif self.phase == "wifi":
            receiver = udp or self.udp
            line = receiver.request_control(
                bytes([CMD_CONNECTION_STATUS]), "$STATUS:",
                timeout=2, attempts=4,
            )
            status = dict(
                pair.split("=", 1)
                for pair in line.removeprefix("$STATUS:").split(",")
            )
        else:
            raise RuntimeError("HIL_UNKNOWN_TRANSPORT_PHASE")
        self.heap_samples.append(int(status["heap"]))
        require(status["bt"] == ("1" if self.phase == "setup" else "0"),
                "HIL_BOOT_TRANSPORT_MISMATCH")
        require(status["camera"] == "1", "HIL_CAMERA_UNAVAILABLE")
        require(status["errors"] == "0", "HIL_FRAME_ERRORS")
        require(status["notify_errors"] == "0", "HIL_NOTIFICATION_ERRORS")
        return status

    def photo(self, name: str, size=(320, 240)):
        stamp, data = self.client.frame()
        del stamp
        details = decode_jpeg(data, size, self.output / "frames" / f"{name}.jpg")
        self.images[name] = details
        return details

    def wifi_config_get(self):
        since = time.monotonic()
        self.client.write(b"\x08")
        return self.client.line("$WIFI_CFG:ssid=", since).removeprefix("$WIFI_CFG:ssid=")

    def provision(self, ssid: str, password: str):
        self.checkpoint()
        self.wifi_dirty = True
        result = self.client.wifi_config_put(ssid, password)
        self.checkpoint()
        return result

    def wait_wifi(self):
        deadline = time.monotonic() + WIFI_TIMEOUT
        while time.monotonic() < deadline:
            status = self.status()
            if status["wifi"] == "connected" and status["ip"] != "0.0.0.0":
                require(re.fullmatch(r"(?:\d{1,3}\.){3}\d{1,3}", status["ip"]) is not None,
                        "HIL_WIFI_INVALID_IP")
                return status
            self.client.pump(0.5)
        raise TimeoutError("HIL_WIFI_CONNECT_TIMEOUT")

    def verify_wifi_boot(self, since: int):
        self.uart.wait(r"rst:.*RESET", since, code="HIL_REBOOT_NOT_OBSERVED")
        self.uart.wait(r"operation=boot.mode mode=wifi_only ble=0", since,
                       code="HIL_WIFI_ONLY_BOOT_MISSING")
        self.uart.wait(r"operation=boot.ready camera=1", since,
                       code="HIL_CAMERA_BOOT_FAILED")
        match = self.uart.wait(r"operation=wifi.got_ip ip=([0-9.]+)", since,
                               WIFI_TIMEOUT, "HIL_WIFI_CONNECT_TIMEOUT")
        self.uart.wait(r"UDP socket bound on port", since,
                       code="HIL_UDP_LISTENER_NOT_READY")
        text = self.uart.text(since)
        require("operation=ble.init" not in text and "operation=ble.advertise" not in text,
                "HIL_BLE_STARTED_IN_WIFI_MODE")
        self.phase = "wifi"
        return match.group(1)

    def assert_udp_quiet(self):
        # STREAM_OFF can race one frame already being captured/sent. Allow that
        # in-flight frame (or its partial fragments) to settle, then drain and
        # preserve its frame-ID watermark before enforcing the quiet interval.
        previous_dropped = self.udp.dropped_frames
        try:
            self.udp.next_frame(timeout=0.9)
        except TimeoutError as exc:
            require(str(exc) == "HIL_UDP_FRAME_TIMEOUT", "HIL_UNEXPECTED_UDP_TIMEOUT")
        self.udp.drain()
        settled_frame_id = self.udp.last_frame_id

        try:
            self.udp.next_frame(timeout=IDLE_SECONDS)
        except TimeoutError as exc:
            require(str(exc) == "HIL_UDP_FRAME_TIMEOUT", "HIL_UNEXPECTED_UDP_TIMEOUT")
        else:
            raise AssertionError("HIL_UDP_UNEXPECTED_FRAME")
        require(
            self.udp.last_frame_id == settled_frame_id
            and self.udp.frame_id is None
            and not self.udp.parts
            and self.udp.dropped_frames == previous_dropped,
            "HIL_UDP_UNEXPECTED_FRAME",
        )

    def udp_control(self, code: int):
        since = self.uart.mark()
        self.udp.command(bytes([code]))
        self.uart.wait(r"operation=command.execute transport=udp .*command=0x"
                       + f"{code:02x}" + r" .*outcome=success", since,
                       REPLY_TIMEOUT, "HIL_UDP_COMMAND_NOT_EXECUTED")

    def pairing_authorization(self):
        require(not self.client.paired, "HIL_CLIENT_PAIR_STATE_STALE")
        cases = (bytes([CMD_BLE_PAIR]) + b"22222",
                 bytes([CMD_BLE_PAIR]) + b"1111",
                  bytes([CMD_BLE_PAIR]) + b"111111",
                  bytes([CMD_WIFI_CONFIG_PUT]) + b"TestAP\0TestPass123\0",
                  bytes([CMD_WIFI_CONFIG_PUT]) + b"\0\0",
                  bytes([CMD_REBOOT]))
        for packet in cases:
            self.rejected_write(packet, "HIL_UNAUTHORIZED_COMMAND_ACCEPTED")
            self.status()
        self.client.pair(BLE_PAIRING_CODE)
        require(self.wifi_config_get() == "", "HIL_UNAUTHORIZED_WIFI_SIDE_EFFECT")
        self.reboot_without_credentials()
        self.client.disconnect()
        self.client.connect()
        self.rejected_write(bytes([CMD_WIFI_CONFIG_PUT]) + b"TestAP\0TestPass123\0",
                            "HIL_PAIRING_SURVIVED_RECONNECT")
        require(self.wifi_config_get() == "", "HIL_UNAUTHORIZED_WIFI_SIDE_EFFECT")
        self.client.pair(BLE_PAIRING_CODE)
        return {"rejected_commands": len(cases), "session_authorization_reset": True,
                "paired_reboot_without_credentials_rejected": True}

    def reboot_without_credentials(self):
        """An authorized reboot still requires saved credentials; keep setup alive."""
        mark = self.uart.mark()
        since = time.monotonic()
        self.client.command(CMD_REBOOT)
        reply = self.client.line("$ERROR:WIFI_CONFIG_REQUIRED", since, REPLY_TIMEOUT)
        require(reply == "$ERROR:WIFI_CONFIG_REQUIRED", "HIL_REBOOT_GUARD_REPLY_MISMATCH")
        self.client.pump(IDLE_SECONDS)
        require(re.search(r"rst:.*RESET", self.uart.text(mark)) is None,
                "HIL_REBOOT_WITHOUT_CREDENTIALS")
        require(self.status()["wifi"] == "disconnected", "HIL_REBOOT_GUARD_SETUP_LOST")

    def rejected_write(self, packet: bytes, code: str):
        try:
            self.client.write(packet)
        except self.client.dbus.DBusException as exc:
            require(is_gatt_rejection(exc), "HIL_BLE_REJECTION_TRANSPORT_ERROR")
        else:
            raise AssertionError(code)

    def advertisement_and_gatt(self):
        advertisement = self.client.discover()
        contract = self.client.connect()
        status = self.status()
        require(int(status["psram"]) >= 4 * 1024 * 1024, "HIL_PSRAM_UNAVAILABLE")
        return {**advertisement, **contract, "psram_bytes": int(status["psram"]),
                "sensor_available": status["sensor"] == "1"}

    def malformed_ble(self):
        self.client.command(0, "$CMD:stream_off")
        original = self.wifi_config_get()
        cases = (b"", b"\xff", b"\x03\x00", b"\x07no-terminator",
                 b"\x07TestAP\0short\0", b"\x07" + b"x" * 100)
        for packet in cases:
            self.rejected_write(packet, "HIL_MALFORMED_COMMAND_ACCEPTED")
        status = self.status()
        require(status["flash"] == "0" and status["stream"] == "0", "HIL_INVALID_WRITE_SIDE_EFFECT")
        require(self.wifi_config_get() == original, "HIL_INVALID_WIFI_SIDE_EFFECT")
        return {"rejected_writes": len(cases)}

    def single_frame(self):
        self.client.command(0, "$CMD:stream_off")
        self.client.clear_frames()
        count = int(self.status()["frames"])
        self.client.command(2, "$CMD:single_frame")
        image = self.photo("ble-single")
        self.client.pump(IDLE_SECONDS)
        require(not self.client.frames, "HIL_SINGLE_FRAME_RESUMED_STREAM")
        status = self.status()
        require(int(status["frames"]) == count + 1 and status["stream"] == "0", "HIL_SINGLE_FRAME_COUNT")
        return image

    def queued_single_frames(self):
        self.client.clear_frames()
        count = int(self.status()["frames"])
        for _ in range(3):
            self.client.write(b"\x02")
        for index in range(3):
            self.photo(f"ble-queued-{index}")
        self.client.pump(IDLE_SECONDS)
        require(not self.client.frames, "HIL_QUEUED_EXTRA_FRAME")
        status = self.status()
        require(int(status["frames"]) == count + 3 and status["stream"] == "0", "HIL_QUEUED_FRAME_COUNT")
        return {"requested": 3, "decoded": 3}

    def flashlight(self):
        try:
            self.client.command(3, "$CMD:flash_on")
            require(self.status()["flash"] == "1", "HIL_FLASH_ON_FAILED")
            self.client.pump(0.2)
            self.client.command(2, "$CMD:single_frame")
            on = self.photo("flash-on")
        finally:
            # Local cleanup must not replace an operation error with cancellation.
            self.local_cleanup(self.client.command, CMD_FLASH_OFF, "$CMD:flash_off")
        require(self.status()["flash"] == "0", "HIL_FLASH_OFF_FAILED")
        self.client.pump(0.2)
        self.client.command(2, "$CMD:single_frame")
        off = self.photo("flash-off")
        return {"gpio_on_off": True, "on_luminance": on["mean_luminance"],
                "off_luminance": off["mean_luminance"]}

    def ble_stream(self):
        self.client.clear_frames()
        self.client.command(1, "$CMD:stream_on")
        times = []
        for index in range(3):
            stamp, data = self.client.frame()
            times.append(stamp)
            decode_jpeg(data, BLE_FRAME_SIZE, self.output / "frames" / f"ble-stream-{index}.jpg")
        self.client.command(0, "$CMD:stream_off")
        self.client.clear_frames()
        self.client.pump(IDLE_SECONDS)
        require(not self.client.frames and self.status()["stream"] == "0", "HIL_BLE_PAUSE_FAILED")
        return {"decoded_frames": len(times), "received_fps": round(2 / (times[-1] - times[0]), 2)}

    def unsubscribe(self):
        self.client.subscribe(False)
        self.client.pump(0.3)
        count = self.client.notifications
        self.client.write(b"\x09")
        self.client.pump(0.5)
        require(self.client.notifications == count, "HIL_UNSUBSCRIBED_NOTIFICATION")
        self.client.subscribe(True)
        self.status()
        return {"unsubscribe_resubscribe": True}

    def reconnect(self):
        for _ in range(3):
            self.client.command(3, "$CMD:flash_on")
            self.client.disconnect()
            self.client.discover()
            self.client.connect()
            status = self.status()
            require(status["flash"] == "0" and status["stream"] == "0", "HIL_DISCONNECT_CLEANUP_FAILED")
        return {"reconnects": 3}

    def wifi_boundaries(self):
        self.client.pair(BLE_PAIRING_CODE)
        length = self.provision("S" * MAX_SSID_BYTES, "a" * MAX_PASSWORD_BYTES)
        ssid_result = self.wifi_config_get()
        require(length == 1 + MAX_SSID_BYTES + 1 + MAX_PASSWORD_BYTES + 1 and
                ssid_result == "S" * MAX_SSID_BYTES, "HIL_MAX_WIFI_PAYLOAD_TRUNCATED")
        require(self.status()["wifi"] == "disconnected", "HIL_WIFI_STARTED_DURING_SETUP")
        return {"write_bytes": length, "ssid_bytes": MAX_SSID_BYTES, "psk_bytes": MAX_PASSWORD_BYTES}

    def wifi_connect(self):
        require(self.wifi is not None, "HIL_WIFI_CREDENTIALS_REQUIRED")
        self.client.pair(BLE_PAIRING_CODE)
        self.client.esp_mac = self.client.esp_hostname = None
        since = time.monotonic()
        self.provision(*self.wifi)
        mac = self.client.line("$ESP_MAC:", since).removeprefix("$ESP_MAC:")
        hostname = self.client.line("$ESP_NAME:", since).removeprefix("$ESP_NAME:")
        require(re.fullmatch(r"(?:[0-9A-F]{2}:){5}[0-9A-F]{2}", mac) is not None,
                "HIL_BLE_INVALID_ESP_MAC")
        require(re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9-]{0,62}", hostname) is not None,
                "HIL_BLE_INVALID_ESP_HOSTNAME")
        require(self.wifi_config_get() == self.wifi[0], "HIL_WIFI_CONFIG_MISMATCH")
        require(self.status()["wifi"] == "disconnected", "HIL_WIFI_STARTED_DURING_SETUP")
        self.wifi_dirty = False
        mark = self.uart.mark()
        self.client.reboot()
        self.client.wait(lambda: not self.client.manager.GetManagedObjects().get(
            self.client.device_path, {}).get("org.bluez.Device1", {}).get("Connected", False),
            REPLY_TIMEOUT, "HIL_REBOOT_DID_NOT_DISCONNECT_BLE")
        self.client.disconnect()
        ip = self.verify_wifi_boot(mark)
        require("SW_CPU_RESET" in self.uart.text(mark), "HIL_SOFTWARE_RESET_NOT_OBSERVED")
        self.client.assert_not_advertising(BLE_SCAN_SECONDS)
        self.udp = self.receiver(ip)
        self.checkpoint()
        status = self.status()
        require(status["wifi"] == "connected" and status["ip"] == ip,
                "HIL_WIFI_STATUS_MISMATCH")
        return {"wifi": status["wifi"], "esp_mac": mac, "esp_hostname": hostname,
                "ip": ip, "ble_initialized": False, "ble_scan_seconds": BLE_SCAN_SECONDS,
                "software_reboot_observed": True, "heap_bytes": int(status["heap"])}

    def ble_pair_and_wifi_config(self):
        """Run the setup-to-WiFi transition without reconnecting BLE."""
        return self.wifi_connect()

    def udp_single(self):
        self.udp.drain()
        before = self.status()
        require(before["stream"] == "0", "HIL_UDP_SINGLE_NOT_PAUSED")
        self.udp.command(bytes([CMD_SINGLE_FRAME]))
        stamp, data = self.udp.next_frame()
        del stamp
        details = decode_jpeg(data, UDP_FRAME_SIZES, self.output / "frames" / "udp-single.jpg")
        self.assert_udp_quiet()
        status = self.status()
        require(int(status["frames"]) == int(before["frames"]) + 1 and status["stream"] == "0",
                "HIL_UDP_SINGLE_COUNT")
        details["late_fragments_ignored"] = self.udp.stale_datagrams
        return details

    def udp_stream(self):
        self.udp.drain()
        self.udp.command(b"\x01")
        times = []
        for index in range(UDP_TEST_FRAMES):
            stamp, frame = self.udp.next_frame()
            times.append(stamp)
            decode_jpeg(frame, UDP_FRAME_SIZES, self.output / "frames" / f"udp-stream-{index}.jpg")
        self.udp_control(CMD_STREAM_OFF)
        self.udp.drain()
        self.assert_udp_quiet()
        require(self.status()["stream"] == "0", "HIL_UDP_PAUSE_FAILED")
        return {"decoded_frames": len(times), "received_fps": round((len(times) - 1) / (times[-1] - times[0]), 2),
                "packets": self.udp.packets, "incomplete_frames": self.udp.dropped_frames}

    def udp_controls_and_peer(self):
        attacker = self.receiver(self.udp.peer[0])
        try:
            self.checkpoint()
            self.udp_control(CMD_STREAM_ON)
            self.udp.next_frame()
            self.udp_control(CMD_FLASH_ON)
            require(self.status()["flash"] == "1", "HIL_UDP_FLASH_ON_FAILED")
            self.udp_control(CMD_FLASH_OFF)
            require(self.status()["flash"] == "0", "HIL_UDP_FLASH_OFF_FAILED")
            before = self.uart.mark()
            for packet in (b"", b"\xff", b"\x00\x01", b"\x07"):
                attacker.command(packet)
            attacker.command(b"\x03")
            stamp, data = self.udp.next_frame()
            del stamp
            decode_jpeg(data, UDP_FRAME_SIZES, self.output / "frames" / "udp-after-invalid.jpg")
            require(self.status()["flash"] == "0", "HIL_OTHER_PEER_CONTROL_ACCEPTED")
            require(re.search(r"operation=command.execute transport=udp .*command=0x(?:03|07)",
                              self.uart.text(before)) is None, "HIL_INVALID_UDP_COMMAND_EXECUTED")
            attacker.command(b"\x01")
            stamp, data = attacker.next_frame()
            del stamp
            decode_jpeg(data, UDP_FRAME_SIZES, self.output / "frames" / "udp-new-peer.jpg")
            self.status(udp=attacker)
            self.udp.drain()
            self.assert_udp_quiet()
            attacker.command(b"\x00")
            require(self.status(udp=attacker)["stream"] == "0", "HIL_NEW_PEER_PAUSE_FAILED")
            self.udp.command(bytes([CMD_SINGLE_FRAME]))
            _, data = self.udp.next_frame()
            decode_jpeg(data, UDP_FRAME_SIZES, self.output / "frames" / "udp-peer-restored.jpg")
            return {"flash_on_off": True, "invalid_and_other_peer_commands_not_executed": True,
                    "unicast_handover": True, "original_peer_reclaimed": True}
        finally:
            self.local_cleanup(attacker.close)

    def wifi_reconfiguration_and_retry(self):
        """Reconfigure and erase in setup; WiFi must remain stopped throughout."""
        missing_ssid = "SLP-HIL-" + uuid.uuid4().hex[:12]
        self.client.pair(BLE_PAIRING_CODE)
        self.provision(missing_ssid, TEST_PASSWORD)
        require(self.wifi_config_get() == missing_ssid, "HIL_WIFI_RECONFIGURATION_FAILED")
        require(self.status()["wifi"] == "disconnected", "HIL_WIFI_STARTED_DURING_SETUP")
        self.client.wifi_erase()
        require(self.wifi_config_get() == "", "HIL_WIFI_ERASE_LIVE_STATE_FAILED")
        self.wifi_dirty = False
        require("operation=wifi.start" not in self.uart.text(), "HIL_WIFI_STARTED_DURING_SETUP")
        return {"reconfigured_ssid_readback": True, "erased_ssid_readback": True,
                "wifi_started_during_setup": False}

    def restart_empty_nvs(self):
        mark = self.uart.mark()
        self.client.command(CMD_RESTART, "$CMD:restart")
        self.client.wait(lambda: not self.client.manager.GetManagedObjects().get(
            self.client.device_path, {}).get("org.bluez.Device1", {}).get("Connected", False),
            REPLY_TIMEOUT, "HIL_RESTART_DID_NOT_DISCONNECT")
        self.client.disconnect()
        self.uart.wait(r"operation=boot.mode mode=ble_setup ble=1", mark,
                       code="HIL_ERASED_NVS_BOOT_FAILED")
        self.uart.wait(r"operation=ble.advertise", mark, code="HIL_BLE_RESTART_ADVERTISEMENT_MISSING")
        self.client.discover()
        self.client.connect()
        require(self.wifi_config_get() == "" and self.status()["wifi"] == "disconnected",
                "HIL_WIFI_ERASE_NOT_PERSISTED")
        require("SW_CPU_RESET" in self.uart.text(mark), "HIL_SOFTWARE_RESET_NOT_OBSERVED")
        return {"software_restart_observed": True,
                "erased_credentials_persisted": True}

    def restart(self):
        self.udp.close()
        self.udp = None
        mark = self.uart.reset()
        ip = self.verify_wifi_boot(mark)
        self.udp = self.receiver(ip)
        self.checkpoint()
        self.udp.command(bytes([CMD_SINGLE_FRAME]))
        _, data = self.udp.next_frame()
        details = decode_jpeg(data, UDP_FRAME_SIZES, self.output / "frames" / "udp-after-reset.jpg")
        self.assert_udp_quiet()
        self.client.assert_not_advertising(BLE_SCAN_SECONDS)
        return {"hardware_reset_observed": True, "wifi_credentials_persisted": True,
                "wifi_connected": True, "ble_initialized": False, "udp_image": details}

    def standby_and_resume(self):
        self.client.command(6, "$CMD:shutdown_complete")
        self.client.pump(2.5)
        status = self.status()
        require(status["standby"] == "1" and status["wifi"] == "disconnected" and
                status["stream"] == "0" and status["flash"] == "0", "HIL_STANDBY_FAILED")
        self.client.command(1, "$CMD:stream_on")
        self.photo("ble-after-standby")
        self.client.command(0, "$CMD:stream_off")
        require(self.status()["standby"] == "0", "HIL_RESUME_FAILED")
        return {"standby": True, "ble_recovery": True}

    def wifi_integrity(self):
        status = self.status()
        text = (self.output / "uart.log").read_text(errors="replace")
        require(
            re.search(r"Guru Meditation|Brownout|abort\\(\\)|panic'ed|assert failed", text, re.I) is None,
            "HIL_UART_RUNTIME_FAULT",
        )
        if status["sensor"] == "0":
            require("$UV:" not in text, "HIL_FABRICATED_SENSOR_READING")
        require(status["bt"] == "0", "HIL_BLE_STARTED_IN_WIFI_MODE")
        return {
            "frame_errors": int(status["errors"]),
            "notification_errors": int(status["notify_errors"]),
            "heap_bytes": int(status["heap"]),
            "minimum_internal_heap_bytes": int(status["min_heap"]),
            "udp_datagrams": self.udp.datagrams if self.udp else 0,
            "accepted_fragments": self.udp.packets if self.udp else 0,
            "incomplete_frames": self.udp.dropped_frames if self.udp else 0,
            "runtime_faults": 0,
        }

    def integrity(self):
        self.client.pump(1)
        status = self.status()
        require(self.client.max_notification_bytes <= 500, "HIL_NOTIFICATION_TOO_LARGE")
        require(self.client.protocol_errors == 0, "HIL_CLIENT_REASSEMBLY_ERRORS")
        text = (self.output / "uart.log").read_text(errors="replace")
        require(re.search(r"Guru Meditation|Brownout|abort\(\)|panic'ed|assert failed", text, re.I) is None,
                "HIL_UART_RUNTIME_FAULT")
        if status["sensor"] == "0":
            require(not any(line.startswith("$UV:") for _, line in self.client.lines), "HIL_FABRICATED_SENSOR_READING")
        return {"max_notification_bytes": self.client.max_notification_bytes,
                "notifications": self.client.notifications, "frame_errors": int(status["errors"]),
                "notification_errors": int(status["notify_errors"]), "heap_bytes": int(status["heap"]),
                "minimum_internal_heap_bytes": int(status["min_heap"]), "runtime_faults": 0}

    def run(self):
        try:
            self.checkpoint()
            require(self.uart is not None, "HIL_UART_REQUIRED")
            self.case("initial_commissioning", self.initial_commissioning)
            if self.phase == "wifi":
                self.case("udp_single_frame", self.udp_single)
                self.case("udp_stream_and_pause", self.udp_stream)
                self.case("udp_single_after_pause", self.udp_single)
                self.case("udp_controls_and_peer_handover", self.udp_controls_and_peer)
                self.case("restart_and_nvs_recovery", self.restart)
                self.case("final_integrity", self.wifi_integrity)
                return

            self.case("advertisement_and_gatt", self.advertisement_and_gatt)
            if self.wifi_recovery_boot and self.wifi is not None:
                # A saved-WiFi recovery boot is already evidence that the old
                # credential failed. Re-provision from the active NM profile
                # before running unrelated BLE-negative tests that would delay
                # restoration of the actual UDP video path.
                self.case("wifi_provisioning_from_recovery", self.wifi_connect)
                self.case("udp_single_frame", self.udp_single)
                self.case("udp_stream_and_pause", self.udp_stream)
                self.case("udp_single_after_pause", self.udp_single)
                self.case("udp_controls_and_peer_handover", self.udp_controls_and_peer)
                self.case("restart_and_nvs_recovery", self.restart)
                self.case("final_integrity", self.wifi_integrity)
                return
            self.case("malformed_ble_commands", self.malformed_ble)
            self.case("paused_single_frame", self.single_frame)
            self.case("queued_single_frames", self.queued_single_frames)
            self.case("flashlight_and_real_images", self.flashlight)
            self.case("ble_stream_and_pause", self.ble_stream)
            self.case("unsubscribe_resubscribe", self.unsubscribe)
            self.case("disconnect_cleanup_and_reconnect", self.reconnect)
            self.case("pairing_authorization", self.pairing_authorization)
            self.case("wifi_maximum_payload", self.wifi_boundaries)
            self.case("wifi_reconfiguration_and_erase", self.wifi_reconfiguration_and_retry)
            self.case("restart_and_erased_nvs", self.restart_empty_nvs)
            self.case("standby_and_resume", self.standby_and_resume)
            if self.wifi is not None:
                self.case("wifi_provisioning", self.wifi_connect)
                self.case("udp_single_frame", self.udp_single)
                self.case("udp_stream_and_pause", self.udp_stream)
                self.case("udp_single_after_pause", self.udp_single)
                self.case("udp_controls_and_peer_handover", self.udp_controls_and_peer)
                self.case("restart_and_nvs_recovery", self.restart)
            self.case("final_integrity", self.integrity)
        except BaseException as exc:
            if self.primary_failure is None:
                self.primary_failure = exc
            raise
        finally:
            self.cleanup()

    def cleanup(self, disconnect=True):
        failed = sys.exc_info()[0] is not None or self.primary_failure is not None
        if self.interruption is not None:
            self.interruption.begin_cleanup()
        cleanup = []
        if self.phase == "setup" and self.client.rx is not None:
            # Cleanup never resends or erases credentials, even after a lost reply.
            cleanup.extend(((self.client.command, (CMD_STREAM_OFF, "$CMD:stream_off")),
                            (self.client.command, (CMD_FLASH_OFF, "$CMD:flash_off"))))
        elif self.udp is not None:
            cleanup.extend(((self.udp_control, (CMD_STREAM_OFF,)),
                            (self.udp_control, (CMD_FLASH_OFF,))))
        if disconnect:
            cleanup.append((self.client.disconnect, ()))
        if self.udp is not None:
            cleanup.append((self.udp.close, ()))
        for operation, arguments in cleanup:
            try:
                operation(*arguments)
            except BaseException as exc:
                self.cleanup_errors.append(type(exc).__name__)
        if self.cleanup_errors:
            print("HIL_CLEANUP_INCOMPLETE", file=sys.stderr)
            if not failed:
                raise RuntimeError("HIL_CLEANUP_INCOMPLETE") from None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True, help="ESP32 UART port")
    parser.add_argument("--adapter", default=DEFAULT_ADAPTER)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--wifi-from-nm", action="store_true", help="Provision the laptop's active WiFi profile")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    suite = None
    uart = None
    cleanup_errors = []
    failure = None
    interruption = StandaloneSignals()
    try:
        with interruption:
            with interruption.owned(HardwareLock(args.adapter, args.port)):
                client = None
                try:
                    interruption.checkpoint()
                    wifi = network_manager_credentials(interruption) if args.wifi_from_nm else None
                    interruption.checkpoint()
                    if not wifi and os.environ.get("SPECTRULENPOR_TEST_SSID"):
                        wifi = (os.environ["SPECTRULENPOR_TEST_SSID"], os.environ.get("SPECTRULENPOR_TEST_PASSWORD", ""))
                    client = BluezClient(args.adapter)
                    interruption.checkpoint()
                    interruption.bind_client(client)
                    suite = HardwareSuite(client, args.output, wifi)
                    suite.interruption = interruption
                    interruption.checkpoint()
                    uart = UARTLog(args.port, args.output / "uart.log")
                    interruption.checkpoint()
                    with interruption.owned(uart):
                        suite.uart = uart
                        interruption.bind_uart(uart)
                        interruption.checkpoint()
                        suite.run()
                        require(uart.error is None, "HIL_UART_CAPTURE_ERROR")
                finally:
                    interruption.begin_cleanup()
                    failed = sys.exc_info()[0] is not None
                    if uart is not None:
                        cleanup_errors.extend(getattr(uart, "cleanup_errors", ()))
                    if client is not None:
                        try:
                            client.disconnect()
                        except BaseException as exc:
                            cleanup_errors.append(type(exc).__name__)
                            if not failed:
                                raise RuntimeError("HIL_CLEANUP_INCOMPLETE") from None
    except BaseException as exc:
        failure = StandaloneInterrupted(interruption.code) if isinstance(exc, KeyboardInterrupt) else exc
    failure = interruption.final_failure(failure)
    error = type(failure).__name__ if failure is not None else None
    error_code = None
    if failure is not None:
        error_code = (failure.code if isinstance(failure, TestbenchError) else
                      str(failure) if isinstance(failure, (AssertionError, RuntimeError, TimeoutError)) else "HIL_TEST_FAILED")
        print(f"HIL_RUN_FAILED: {error_code} ({error})", file=sys.stderr)
    report = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "ok": error is None,
        "error_type": error,
        "code": error_code,
        "cases": suite.records if suite else [],
        "images": suite.images if suite else {},
        "sensor_hardware": "not verified when unavailable; no synthesized readings",
        "wifi_requested": bool(suite and suite.wifi),
        "wifi_tested": bool(suite and any(case["name"] == "udp_single_frame" and case.get("ok")
                                         for case in suite.records)),
        "wifi_skipped_reason": "HIL_WIFI_CREDENTIALS_NOT_SUPPLIED" if suite and not suite.wifi else None,
        "cleanup_errors": (suite.cleanup_errors if suite else []) + cleanup_errors + interruption.cleanup_errors,
        "configuration_may_require_recovery": bool(suite and suite.wifi_dirty),
        "interrupted": interruption.signum is not None or isinstance(failure, StandaloneInterrupted),
    }
    (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"ok": report["ok"], "passed": sum(case.get("ok", False) for case in report["cases"]),
                      "total": len(report["cases"]), "wifi_tested": report["wifi_tested"]}, indent=2))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
