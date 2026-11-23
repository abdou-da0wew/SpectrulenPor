"""Desktop Wi-Fi discovery through NetworkManager."""
from __future__ import annotations
import re
import subprocess
from dataclasses import dataclass

@dataclass(frozen=True, slots=True)
class WifiNetwork:
    ssid: str
    signal: int
    security: str
    active: bool = False

def run_nmcli(*args: str, timeout: float = 12.0) -> str:
    result = subprocess.run(["nmcli", "--terse", "--escape", "yes", *args],
        text=True, capture_output=True, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or "NetworkManager command failed")
    return result.stdout.strip()

def split_escaped(line: str) -> list[str]:
    fields, current = [], []
    escaped = False
    for char in line:
        if escaped:
            current.append(char); escaped = False
        elif char == "\\":
            escaped = True
        elif char == ":":
            fields.append("".join(current)); current = []
        else:
            current.append(char)
    fields.append("".join(current))
    return fields

def wifi_interfaces() -> list[str]:
    output = run_nmcli("-f", "DEVICE,TYPE,STATE", "device", "status")
    devices = []
    for line in output.splitlines():
        fields = split_escaped(line)
        if len(fields) >= 2 and fields[1] == "wifi":
            devices.append(fields[0])
    return devices

def default_wifi_interface() -> str | None:
    try:
        output = subprocess.run(["ip", "-o", "route", "show", "default"],
            text=True, capture_output=True, timeout=3, check=False).stdout
        for line in output.splitlines():
            fields = line.split()
            if "dev" in fields:
                candidate = fields[fields.index("dev") + 1]
                if candidate in wifi_interfaces():
                    return candidate
    except (OSError, subprocess.TimeoutExpired):
        pass
    return next(iter(wifi_interfaces()), None)

def current_ssid(interface: str | None = None) -> str:
    args = ["-f", "IN-USE,SSID", "device", "wifi", "list"]
    if interface: args.extend(["ifname", interface])
    for line in run_nmcli(*args).splitlines():
        fields = split_escaped(line)
        if len(fields) >= 2 and fields[0] == "*":
            return fields[1]
    return ""

def scan_wifi(interface: str | None = None) -> list[WifiNetwork]:
    args = ["-f", "IN-USE,SSID,SIGNAL,SECURITY", "device", "wifi", "list", "--rescan", "yes"]
    if interface: args.extend(["ifname", interface])
    networks = {}
    for line in run_nmcli(*args, timeout=18).splitlines():
        fields = split_escaped(line)
        if len(fields) < 4 or not fields[1]:
            continue
        active, ssid, signal, security = fields[:4]
        try: strength = int(signal)
        except ValueError: strength = 0
        item = WifiNetwork(ssid, strength, security or "Open", active == "*")
        if ssid not in networks or item.signal > networks[ssid].signal:
            networks[ssid] = item
    return sorted(networks.values(), key=lambda item: (not item.active, -item.signal, item.ssid.lower()))
