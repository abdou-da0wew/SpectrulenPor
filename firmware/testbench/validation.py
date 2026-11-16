"""Validate action shapes and credential bytes before a command can be queued."""

import ipaddress
import math
import re

from .errors import TestbenchError
from .settings import (MAX_SOAK_SECONDS, MIN_SOAK_SECONDS, PROFILES, DEFAULT_SOAK_SECONDS,
                       WIFI_MAX_SSID_BYTES, WIFI_MAX_PASSWORD_BYTES, WIFI_MIN_PASSWORD_BYTES)

ACTION_FIELDS = {
    "connect": {"adapter"},
    "setup": {"wifi_from_nm", "ssid", "password"},
    "reboot": set(),
    "attach": {"ip"},
    "stream": {"enabled"},
    "single": set(),
    "flash": {"enabled"},
    "disconnect": set(),
    "test": {"profile", "confirm_configuration", "duration", "duration_seconds", "wifi_from_nm", "ssid", "password", "ip"},
    "cancel": set(),
}
ADAPTER_PATTERN = re.compile(r"hci[0-9]{1,3}\Z")
MAC_PATTERN = re.compile(r"(?:[0-9A-F]{2}:){5}[0-9A-F]{2}\Z")
HOSTNAME_PATTERN = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9-]{0,62}\Z")


def adapter_name(value):
    if not isinstance(value, str) or not ADAPTER_PATTERN.fullmatch(value):
        raise TestbenchError("TB_INVALID_ADAPTER", "INVALID_REQUEST")
    return value


def peer_ip(value):
    try:
        address = ipaddress.IPv4Address(value)
    except (ValueError, TypeError):
        raise TestbenchError("TB_INVALID_IP", "INVALID_REQUEST") from None
    if address.is_unspecified or address.is_multicast or address.is_loopback or address.is_reserved or str(address) == "255.255.255.255":
        raise TestbenchError("TB_INVALID_IP", "INVALID_REQUEST")
    return str(address)


def wifi_credentials(ssid, password):
    """Accept open WiFi, 8..63 UTF-8 bytes, or a 64-character hexadecimal PSK."""
    if not isinstance(ssid, str) or not isinstance(password, str):
        raise TestbenchError("TB_INVALID_WIFI", "INVALID_WIFI")
    try:
        ssid_bytes, password_bytes = ssid.encode("utf-8"), password.encode("utf-8")
    except UnicodeError:
        raise TestbenchError("TB_INVALID_WIFI", "INVALID_WIFI") from None
    if not 1 <= len(ssid_bytes) <= WIFI_MAX_SSID_BYTES or b"\0" in ssid_bytes or b"\0" in password_bytes:
        raise TestbenchError("TB_INVALID_WIFI", "INVALID_WIFI")
    size = len(password_bytes)
    if size and not (WIFI_MIN_PASSWORD_BYTES <= size < WIFI_MAX_PASSWORD_BYTES
                     or size == WIFI_MAX_PASSWORD_BYTES and re.fullmatch(r"[0-9a-fA-F]{64}", password)):
        raise TestbenchError("TB_INVALID_WIFI", "INVALID_WIFI")
    return ssid, password


def action_request(body):
    if not isinstance(body, dict) or set(body) - {"action", "params"}:
        raise TestbenchError("TB_INVALID_REQUEST", "INVALID_REQUEST")
    action, params = body.get("action"), body.get("params", {})
    if not isinstance(action, str) or action not in ACTION_FIELDS or not isinstance(params, dict) or set(params) - ACTION_FIELDS[action]:
        raise TestbenchError("TB_INVALID_REQUEST", "INVALID_REQUEST")
    params = dict(params)
    if "duration_seconds" in params:
        if "duration" in params:
            raise TestbenchError("TB_INVALID_DURATION", "INVALID_REQUEST")
        params["duration"] = params.pop("duration_seconds")
    if "adapter" in params:
        adapter_name(params["adapter"])
    if "ip" in params:
        params["ip"] = peer_ip(params["ip"])
    if action == "attach" and "ip" not in params:
        raise TestbenchError("TB_INVALID_IP", "INVALID_REQUEST")
    for key in ("enabled", "wifi_from_nm", "confirm_configuration"):
        if key in params and type(params[key]) is not bool:
            raise TestbenchError("TB_INVALID_REQUEST", "INVALID_REQUEST")
    if action in ("stream", "flash") and "enabled" not in params:
        raise TestbenchError("TB_INVALID_REQUEST", "INVALID_REQUEST")
    if "ssid" in params or "password" in params:
        if params.get("wifi_from_nm"):
            raise TestbenchError("TB_INVALID_REQUEST", "INVALID_REQUEST")
        wifi_credentials(params.get("ssid"), params.get("password", ""))
    if action == "setup" and not params.get("wifi_from_nm") and "ssid" not in params:
        raise TestbenchError("TB_WIFI_CREDENTIALS_REQUIRED", "INVALID_WIFI")
    if action == "test":
        if params.get("profile") not in PROFILES:
            raise TestbenchError("TB_INVALID_PROFILE", "INVALID_REQUEST")
        if params["profile"] in ("full", "missing-ap") and not params.get("confirm_configuration"):
            raise TestbenchError("TB_CONFIRM_CONFIGURATION", "CONFIRMATION_REQUIRED")
        duration = params.get("duration", DEFAULT_SOAK_SECONDS)
        if type(duration) not in (int, float) or not math.isfinite(duration) or not MIN_SOAK_SECONDS <= duration <= MAX_SOAK_SECONDS:
            raise TestbenchError("TB_INVALID_DURATION", "INVALID_REQUEST")
    return action, params
