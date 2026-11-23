"""Wire contracts shared with SpectruLenPor ESP32 firmware."""
from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Any

BLE_SERVICE_UUID = "0000ffe0-0000-1000-8000-00805f9b34fb"
BLE_TX_UUID = "0000ffe1-0000-1000-8000-00805f9b34fb"
BLE_RX_UUID = "0000ffe2-0000-1000-8000-00805f9b34fb"
BLE_DEVICE_NAME = "SpectruLenPor-ESP32"
BLE_PAIRING_CODE = "11111"

CMD_STREAM_OFF = 0x00
CMD_STREAM_ON = 0x01
CMD_SINGLE_FRAME = 0x02
CMD_FLASH_ON = 0x03
CMD_FLASH_OFF = 0x04
CMD_RESTART = 0x05
CMD_SHUTDOWN = 0x06
CMD_WIFI_CONFIG_PUT = 0x07
CMD_WIFI_CONFIG_GET = 0x08
CMD_CONNECTION_STATUS = 0x09
CMD_BLE_PAIR = 0x0A
CMD_REBOOT = 0x0B
CMD_UDP_KEEPALIVE = 0x0C
CMD_SET_VIDEO_PROFILE = 0x0D
VIDEO_PROFILE_AUTO = 0xFF

SPECTRAL_CHANNELS = (
    ("A", 410, "AS72653"), ("B", 435, "AS72653"),
    ("C", 460, "AS72653"), ("D", 485, "AS72653"),
    ("E", 510, "AS72653"), ("F", 535, "AS72653"),
    ("G", 560, "AS72652"), ("H", 585, "AS72652"),
    ("R", 610, "AS72651"), ("I", 645, "AS72652"),
    ("S", 680, "AS72651"), ("J", 705, "AS72652"),
    ("T", 730, "AS72651"), ("U", 760, "AS72651"),
    ("V", 810, "AS72651"), ("W", 860, "AS72651"),
    ("K", 900, "AS72652"), ("L", 940, "AS72652"),
)


def encode_video_profile(profile: int) -> bytes:
    """Encode a runtime camera profile command; 0xFF returns to RSSI auto mode."""
    if not isinstance(profile, int) or (profile != VIDEO_PROFILE_AUTO and not 0 <= profile <= 4):
        raise ValueError("Video profile must be 0–4 or VIDEO_PROFILE_AUTO")
    return bytes([CMD_SET_VIDEO_PROFILE, profile])


def parse_spectrum(value: str) -> dict[int, int]:
    """Parse the compact wavelength-to-raw-count status field."""
    readings: dict[int, int] = {}
    for item in str(value).split(";"):
        wavelength, separator, raw = item.partition(":")
        if not separator:
            continue
        try:
            wavelength_nm, raw_count = int(wavelength), int(raw)
        except ValueError:
            continue
        if 300 <= wavelength_nm <= 1200 and 0 <= raw_count <= 65535:
            readings[wavelength_nm] = raw_count
    return readings


UDP_PORT = 8888
UDP_HEADER = struct.Struct("<IIIIII")
UDP_HEADER_BYTES = UDP_HEADER.size
UDP_SAFE_PAYLOAD = 1448
UDP_MTU = 1472
UDP_MAX_FRAME_BYTES = 512 * 1024
UDP_PARITY_FLAG = 0x80000000
UDP_SEQUENCE_MASK = 0x7FFFFFFF
UDP_FEC_GROUP_SIZE = 4


def fec_group_size(total: int) -> int:
    return 1 if 0 < total <= UDP_FEC_GROUP_SIZE else UDP_FEC_GROUP_SIZE


def encode_wifi_credentials(ssid: str, password: str) -> bytes:
    ssid_bytes = ssid.encode("utf-8")
    password_bytes = password.encode("utf-8")
    if not 1 <= len(ssid_bytes) <= 32:
        raise ValueError("SSID must contain 1–32 UTF-8 bytes")
    if b"\0" in ssid_bytes or b"\0" in password_bytes:
        raise ValueError("SSID and password cannot contain NUL bytes")
    if len(password_bytes) not in (0, 64) and not 8 <= len(password_bytes) <= 63:
        raise ValueError("Password must be empty, 8–63 bytes, or a 64-byte PSK")
    if len(password_bytes) == 64 and any(byte not in b"0123456789abcdefABCDEF" for byte in password_bytes):
        raise ValueError("A 64-byte PSK must contain hexadecimal characters only")
    if any(byte < 32 or byte == 127 for byte in ssid_bytes):
        raise ValueError("SSID cannot contain control characters")
    return bytes([CMD_WIFI_CONFIG_PUT]) + ssid_bytes + b"\0" + password_bytes + b"\0"


def parse_status_line(line: str) -> dict[str, Any]:
    """Parse the STATUS key-value wire format without assuming field order."""
    if line.startswith("$STATUS:"):
        line = line[len("$STATUS:"):]
    result: dict[str, Any] = {}
    for part in line.strip().split(","):
        key, separator, value = part.partition("=")
        if not separator:
            continue
        value = value.strip()
        try:
            result[key.strip()] = int(value, 10)
        except ValueError:
            result[key.strip()] = value
    return result


@dataclass(slots=True)
class FramePacket:
    sequence: int
    total: int
    offset: int
    payload_size: int
    frame_id: int
    frame_size: int
    parity: bool
    group: int
    payload: bytes


def decode_video_packet(datagram: bytes) -> FramePacket | None:
    if len(datagram) < UDP_HEADER_BYTES:
        return None
    raw_sequence, total, offset, payload_size, frame_id, frame_size = UDP_HEADER.unpack_from(datagram)
    parity = bool(raw_sequence & UDP_PARITY_FLAG)
    sequence = raw_sequence & UDP_SEQUENCE_MASK
    payload = datagram[UDP_HEADER_BYTES:]
    if not (1 <= total <= (UDP_MAX_FRAME_BYTES + UDP_SAFE_PAYLOAD - 1) // UDP_SAFE_PAYLOAD):
        return None
    if not (4 <= frame_size <= UDP_MAX_FRAME_BYTES):
        return None
    if total != (frame_size + UDP_SAFE_PAYLOAD - 1) // UDP_SAFE_PAYLOAD:
        return None
    if not (0 < payload_size <= UDP_SAFE_PAYLOAD and len(payload) == payload_size):
        return None
    if parity:
        groups = min(total, fec_group_size(total))
        if sequence >= groups or offset != sequence * UDP_SAFE_PAYLOAD:
            return None
        if payload_size != UDP_SAFE_PAYLOAD or offset >= frame_size:
            return None
    elif sequence >= total or offset != sequence * UDP_SAFE_PAYLOAD:
        return None
    elif payload_size != min(UDP_SAFE_PAYLOAD, frame_size - offset):
        return None
    return FramePacket(sequence, total, offset, payload_size, frame_id,
                       frame_size, parity, sequence if parity else 0, payload)
