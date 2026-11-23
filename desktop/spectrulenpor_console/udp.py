"""UDP V2 discovery, control, JPEG reassembly and link telemetry."""
from __future__ import annotations

import ipaddress
import socket
import threading
import time
from collections import deque
from typing import Callable

from .protocol import (
    CMD_CONNECTION_STATUS, CMD_UDP_KEEPALIVE, UDP_HEADER_BYTES,
    UDP_MAX_FRAME_BYTES, UDP_PORT, UDP_SAFE_PAYLOAD, decode_video_packet,
    fec_group_size, parse_status_line,
)


class UdpStreamClient:
    def __init__(self, on_state: Callable[[str], None] | None = None,
                 on_frame: Callable[[bytes, dict], None] | None = None,
                 on_message: Callable[[str], None] | None = None,
                 on_metrics: Callable[[dict], None] | None = None):
        self.on_state = on_state
        self.on_frame = on_frame
        self.on_message = on_message
        self.on_metrics = on_metrics
        self.socket: socket.socket | None = None
        self.peer: tuple[str, int] | None = None
        self._thread: threading.Thread | None = None
        self._stop = threading.Event()
        self._lock = threading.RLock()
        self._manual_ip: str | None = None
        self._last_probe = 0.0
        self._last_status = 0.0
        self._last_keepalive = 0.0
        self._parts: dict[int, bytes] = {}
        self._parity: dict[int, bytes] = {}
        self._frame_id: int | None = None
        self._last_completed_frame_id: int | None = None
        self._frame_total = 0
        self._frame_size = 0
        self._frame_started = 0.0
        self._frames: deque[float] = deque(maxlen=120)
        self._frame_intervals: deque[float] = deque(maxlen=60)
        self._frame_bytes: deque[tuple[float, int]] = deque(maxlen=120)
        self._last_frame_at = 0.0
        self._last_metrics_publish = 0.0
        self._counters = {
            "datagrams": 0, "data_packets": 0, "parity_packets": 0,
            "recovered_fragments": 0, "incomplete_frames": 0,
            "invalid_packets": 0, "control_messages": 0,
            "frames": 0, "frame_bytes": 0,
        }
        self._latest_frame: dict = {}
        self._latest_status: dict = {}

    def _emit_state(self, value: str):
        if self.on_state:
            self.on_state(value)

    def _emit_message(self, value: str):
        if self.on_message:
            self.on_message(value)

    def start(self, target_ip: str | None = None, timeout: float = 14.0):
        with self._lock:
            if self.socket is not None:
                raise RuntimeError("UDP client is already active")
            if target_ip:
                parsed = ipaddress.IPv4Address(target_ip.strip())
                if parsed.is_unspecified or parsed.is_multicast or parsed.is_loopback:
                    raise ValueError("Enter a reachable ESP32 IPv4 address")
                self._manual_ip = str(parsed)
            else:
                self._manual_ip = None
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1_048_576)
            sock.bind(("0.0.0.0", 0))
            sock.settimeout(0.15)
            self.socket = sock
            self.peer = None
            self._stop.clear()
            self._last_probe = self._last_status = self._last_keepalive = 0.0
            self._thread = threading.Thread(target=self._run, name="spectrulenpor-udp", daemon=True)
            self._thread.start()
        self._emit_state("discovering" if not target_ip else "connecting")
        return timeout

    def _send(self, payload: bytes, destination: tuple[str, int] | None = None):
        sock = self.socket
        if sock is None:
            raise RuntimeError("UDP socket is closed")
        target = destination or self.peer
        if target is None:
            raise RuntimeError("ESP32 UDP peer has not been discovered")
        sock.sendto(payload, target)

    def send_command(self, command: int):
        self._send(bytes([command]))

    def send_payload(self, payload: bytes):
        if not payload or len(payload) > 64:
            raise ValueError("Control payload must contain 1–64 bytes")
        self._send(payload)

    def stop_stream(self):
        if self.peer:
            try: self.send_command(0x00)
            except OSError: pass

    def close(self):
        self._stop.set()
        with self._lock:
            sock, self.socket = self.socket, None
            self.peer = None
        if sock:
            try: sock.close()
            except OSError: pass
        thread = self._thread
        if thread and thread.is_alive() and thread is not threading.current_thread():
            thread.join(timeout=1.0)
        self._thread = None
        self._clear_frame()
        self._emit_state("disconnected")

    def _run(self):
        started = time.monotonic()
        self._emit_state("discovering" if not self._manual_ip else "connecting")
        while not self._stop.is_set():
            now = time.monotonic()
            if self.peer is None and now - self._last_probe >= 0.35:
                self._last_probe = now
                target = (self._manual_ip, UDP_PORT) if self._manual_ip else ("255.255.255.255", UDP_PORT)
                try: self._send(bytes([CMD_UDP_KEEPALIVE]), target)
                except OSError as exc: self._emit_message(f"UDP discovery send failed: {exc}")
                if now - started > 18:
                    self._emit_state("not-found")
                    started = now
            elif self.peer is not None:
                if now - self._last_keepalive >= 5:
                    self._last_keepalive = now
                    try: self._send(bytes([CMD_UDP_KEEPALIVE]))
                    except OSError as exc: self._emit_message(f"UDP keepalive failed: {exc}")
                if now - self._last_status >= 2:
                    self._last_status = now
                    try: self._send(bytes([CMD_CONNECTION_STATUS]))
                    except OSError: pass
            sock = self.socket
            if sock is None: break
            try:
                packet, source = sock.recvfrom(65535)
            except socket.timeout:
                self._expire_frame(now)
                self._publish_metrics(now)
                continue
            except OSError:
                break
            with self._lock:
                self._counters["datagrams"] += 1
            if source[1] != UDP_PORT:
                continue
            if self.peer is None:
                if self._manual_ip and source[0] != self._manual_ip:
                    continue
                if packet == bytes([CMD_UDP_KEEPALIVE]) or packet.startswith(b"$CMD:keepalive"):
                    self.peer = source
                    self._last_keepalive = now
                    self._emit_state("connected")
                    self._emit_message(f"UDP peer registered: {source[0]}:{source[1]}")
                    if packet.startswith(b"$CMD:"):
                        self._control(packet)
                    continue
                continue
            if source[0] != self.peer[0] or source[1] != self.peer[1]:
                continue
            if packet.startswith(b"$") or (len(packet) == 1 and packet[0] < 0x20):
                self._control(packet)
            else:
                self._video(packet, now)
            self._publish_metrics(now)
        self._emit_state("disconnected")

    def _control(self, packet: bytes):
        text = packet.decode("utf-8", errors="replace").strip("\r\n\x00 ")
        if not text:
            return
        if text.startswith("$"):
            with self._lock:
                self._counters["control_messages"] += 1
            if text.startswith("$STATUS:"):
                self._latest_status = parse_status_line(text)
            self._emit_message(text)
        elif packet == bytes([CMD_UDP_KEEPALIVE]):
            self._emit_message("$CMD:keepalive")

    @staticmethod
    def _is_newer(candidate: int, reference: int) -> bool:
        difference = (candidate - reference) & 0xFFFFFFFF
        return difference != 0 and difference < 0x80000000

    def _clear_frame(self):
        self._parts.clear()
        self._parity.clear()
        self._frame_id = None
        self._frame_total = 0
        self._frame_size = 0
        self._frame_started = 0.0

    def _expire_frame(self, now: float):
        if self._frame_id is not None and now - self._frame_started > 1.25:
            with self._lock:
                self._counters["incomplete_frames"] += 1
            self._clear_frame()

    def _video(self, datagram: bytes, now: float):
        decoded = decode_video_packet(datagram)
        if decoded is None:
            with self._lock: self._counters["invalid_packets"] += 1
            return
        if self._frame_id is None and decoded.parity and self._last_completed_frame_id is not None:
            if decoded.frame_id == self._last_completed_frame_id or not self._is_newer(
                    decoded.frame_id, self._last_completed_frame_id):
                return  # Ignore delayed parity for a completed or older frame.
        if self._frame_id is None or decoded.frame_id != self._frame_id:
            if self._frame_id is not None:
                if self._is_newer(decoded.frame_id, self._frame_id):
                    with self._lock: self._counters["incomplete_frames"] += 1
                else:
                    return
            self._clear_frame()
            self._frame_id = decoded.frame_id
            self._frame_total = decoded.total
            self._frame_size = decoded.frame_size
            self._frame_started = now
        if decoded.total != self._frame_total or decoded.frame_size != self._frame_size:
            with self._lock: self._counters["invalid_packets"] += 1
            return
        if decoded.parity:
            self._parity[decoded.group] = decoded.payload
            with self._lock: self._counters["parity_packets"] += 1
        else:
            self._parts[decoded.sequence] = decoded.payload
            with self._lock: self._counters["data_packets"] += 1
        self._try_complete(now)

    def _try_complete(self, now: float):
        if self._frame_id is None:
            return
        group_size = fec_group_size(self._frame_total)
        group_count = min(self._frame_total, group_size)
        parts = dict(self._parts)
        recovered = 0
        can_finish = True
        for group in range(group_count):
            members = list(range(group, self._frame_total, group_size))
            missing = [seq for seq in members if seq not in parts]
            if not missing:
                continue
            if len(missing) != 1 or group not in self._parity:
                can_finish = False
                break
            rebuilt = bytearray(self._parity[group])
            for seq in members:
                if seq == missing[0]:
                    continue
                chunk = parts.get(seq)
                if chunk is None:
                    can_finish = False
                    break
                for index, value in enumerate(chunk):
                    rebuilt[index] ^= value
            if not can_finish:
                break
            parts[missing[0]] = bytes(rebuilt[:min(UDP_SAFE_PAYLOAD,
                self._frame_size - missing[0] * UDP_SAFE_PAYLOAD)])
            recovered += 1
        if not can_finish or len(parts) != self._frame_total:
            return
        frame = b"".join(parts[index] for index in range(self._frame_total))
        if len(frame) != self._frame_size or not frame.startswith(b"\xff\xd8") or not frame.endswith(b"\xff\xd9"):
            with self._lock: self._counters["invalid_packets"] += 1
            self._clear_frame()
            return
        frame_id = self._frame_id
        elapsed_ms = (now - self._frame_started) * 1000
        self._last_completed_frame_id = frame_id
        self._clear_frame()
        if recovered:
            with self._lock: self._counters["recovered_fragments"] += recovered
        with self._lock:
            self._counters["frames"] += 1
            self._counters["frame_bytes"] += len(frame)
        if self._last_frame_at:
            self._frame_intervals.append(now - self._last_frame_at)
        self._last_frame_at = now
        self._frames.append(now)
        self._frame_bytes.append((now, len(frame)))
        metadata = {"frame_id": frame_id, "bytes": len(frame), "assembly_ms": elapsed_ms,
                    "recovered": recovered, "fps": self._fps(now)}
        self._latest_frame = metadata
        if self.on_frame:
            self.on_frame(frame, metadata)

    def _fps(self, now: float) -> float:
        while self._frames and now - self._frames[0] > 2.0:
            self._frames.popleft()
        if len(self._frames) < 2:
            return 0.0
        elapsed = self._frames[-1] - self._frames[0]
        return (len(self._frames) - 1) / elapsed if elapsed > 0 else 0.0

    def metrics(self) -> dict:
        now = time.monotonic()
        with self._lock:
            values = dict(self._counters)
        while self._frames and now - self._frames[0] > 2.0: self._frames.popleft()
        while self._frame_bytes and now - self._frame_bytes[0][0] > 2.0: self._frame_bytes.popleft()
        fps = self._fps(now)
        bandwidth = (sum(size for _, size in self._frame_bytes) /
                     max(0.25, min(2.0, now - self._frame_bytes[0][0]))) if self._frame_bytes else 0.0
        jitter = 0.0
        if len(self._frame_intervals) > 1:
            mean = sum(self._frame_intervals) / len(self._frame_intervals)
            jitter = (sum((value - mean) ** 2 for value in self._frame_intervals) / len(self._frame_intervals)) ** 0.5 * 1000
        values.update({"fps": fps, "bandwidth_bps": bandwidth, "jitter_ms": jitter,
                       "peer_ip": self.peer[0] if self.peer else "",
                       "latest_frame": dict(self._latest_frame),
                       "device_status": dict(self._latest_status)})
        return values

    def _publish_metrics(self, now):
        if not self.on_metrics or now - self._last_metrics_publish < 0.25:
            return
        self._last_metrics_publish = now
        self.on_metrics(self.metrics())
