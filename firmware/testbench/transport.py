"""Bounded UDP assembly and single-threaded adapters for the existing HIL clients."""

import io
import sys
import threading
import time
from collections import deque

from .errors import TestbenchError
from .hil import helpers
from .settings import (FRAME_EXPIRY_SECONDS, FRAME_TIMEOUT_SECONDS, MAX_BLE_FRAMES,
                       MAX_PUMP_DATAGRAMS, MAX_UART_BYTES, MAX_UART_POLL_BYTES,
                       MAX_IMAGE_DIMENSION, WORKER_POLL_SECONDS)
from .validation import peer_ip

WIRE = helpers()


def jpeg_dimensions(data: bytes) -> tuple[int, int]:
    """Readiness requires an actual decoder, not just JPEG marker bytes."""
    if not 4 <= len(data) <= WIRE.MAX_FRAME_BYTES or not data.startswith(b"\xff\xd8") or not data.endswith(b"\xff\xd9"):
        raise TestbenchError("TB_INVALID_JPEG")
    try:
        from PIL import Image
    except ImportError:
        try:
            import cv2
            import numpy as np
        except ImportError:
            raise TestbenchError("TB_JPEG_DECODER_MISSING", "DEPENDENCY") from None
        image = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
        if image is None:
            raise TestbenchError("TB_INVALID_JPEG")
        height, width = image.shape[:2]
        if width > MAX_IMAGE_DIMENSION or height > MAX_IMAGE_DIMENSION:
            raise TestbenchError("TB_INVALID_JPEG")
        return width, height
    try:
        with Image.open(io.BytesIO(data)) as image:
            if image.format != "JPEG" or image.width > MAX_IMAGE_DIMENSION or image.height > MAX_IMAGE_DIMENSION:
                raise TestbenchError("TB_INVALID_JPEG")
            image.load()
            return image.size
    except TestbenchError:
        raise
    except Exception:
        raise TestbenchError("TB_INVALID_JPEG") from None


class Reassembler:
    """The firmware has no frame id: only seq=0 can begin a bounded assembly."""

    def __init__(self, peer: tuple[str, int], clock=time.monotonic):
        self.peer, self.clock = peer, clock
        self.parts = {}
        self.total = 0
        self.started = None
        self.datagrams = self.packets = self.dropped_frames = self.protocol_errors = 0
        self.last_incomplete = None

    def drop(self, reason):
        self.last_incomplete = {"received_chunks": len(self.parts), "expected_chunks": self.total,
                                "missing_chunks": max(0, self.total - len(self.parts)),
                                "highest_sequence": max(self.parts) if self.parts else None,
                                "reason": reason}
        self.dropped_frames += 1
        self.clear()

    def clear(self):
        self.parts.clear()
        self.total = 0
        self.started = None

    def expire(self):
        if self.started is not None and self.clock() - self.started >= FRAME_EXPIRY_SECONDS:
            self.drop("expired")

    def feed(self, packet: bytes, source: tuple[str, int]):
        self.expire()
        self.datagrams += 1
        if source != self.peer:
            self.protocol_errors += 1
            return None
        if packet in (bytes([WIRE.CMD_STREAM_ON]), bytes([WIRE.CMD_SINGLE_FRAME])):
            return None
        if len(packet) < WIRE.UDP_HEADER.size:
            self.protocol_errors += 1
            return None
        seq, total, offset, size = WIRE.UDP_HEADER.unpack_from(packet)
        max_parts = (WIRE.MAX_FRAME_BYTES + WIRE.UDP_PAYLOAD_BYTES - 1) // WIRE.UDP_PAYLOAD_BYTES
        if (not 0 < total <= max_parts or seq >= total
                or not 0 < size <= WIRE.UDP_PAYLOAD_BYTES
                or len(packet) != WIRE.UDP_HEADER.size + size
                or offset != seq * WIRE.UDP_PAYLOAD_BYTES
                or offset + size > WIRE.MAX_FRAME_BYTES
                or seq != total - 1 and size != WIRE.UDP_PAYLOAD_BYTES):
            self.protocol_errors += 1
            return None
        payload = packet[WIRE.UDP_HEADER.size:]
        if seq == 0:
            if self.total == total and self.parts.get(0) == payload:
                return None
            if self.parts:
                self.drop("replaced")
            self.clear()
            self.total, self.started = total, self.clock()
        if total != self.total or self.started is None:
            return None
        if seq in self.parts:
            if self.parts[seq] != payload:
                self.protocol_errors += 1
            return None
        self.parts[seq] = payload
        self.packets += 1
        if len(self.parts) == self.total:
            frame = b"".join(self.parts[index] for index in range(self.total))
            self.clear()
            return self.clock(), frame
        return None


class UdpReceiver(WIRE.UdpFrames):
    """One UDP socket for engine, HIL and both frame consumers."""

    def __init__(self, ip, port=WIRE.UDP_PORT, *, cooperate=None, on_frame=None):
        super().__init__(peer_ip(ip), port)
        self.assembly = Reassembler(self.peer)
        self.ready = deque(maxlen=MAX_BLE_FRAMES)
        self.cooperate = cooperate or (lambda: None)
        self.on_frame = on_frame
        self.closed = False
        self.strict = False

    def poll(self):
        self.assembly.expire()
        for _ in range(MAX_PUMP_DATAGRAMS):
            try:
                packet, source = self.socket.recvfrom(WIRE.UDP_HEADER.size + WIRE.UDP_PAYLOAD_BYTES + 1)
            except BlockingIOError:
                break
            errors = self.assembly.protocol_errors
            frame = self.assembly.feed(packet, source)
            if self.strict and self.assembly.protocol_errors != errors:
                raise TestbenchError("HIL_UDP_REASSEMBLY_ERRORS")
            if frame is not None:
                self.ready.append(frame)
        self.parts, self.total = self.assembly.parts, self.assembly.total
        self.datagrams, self.packets = self.assembly.datagrams, self.assembly.packets
        self.dropped_frames = self.assembly.dropped_frames

    def next_frame(self, client=None, timeout=FRAME_TIMEOUT_SECONDS):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            self.cooperate()
            if client is not None:
                client.pump()
            self.poll()
            if self.ready:
                stamp, data = self.ready.popleft()
                if self.on_frame is not None:
                    self.on_frame(stamp, data, "udp")
                return stamp, data
            time.sleep(WORKER_POLL_SECONDS)
        raise TimeoutError("HIL_UDP_FRAME_TIMEOUT")

    def drain(self):
        for _ in range(MAX_PUMP_DATAGRAMS):
            try:
                self.socket.recvfrom(WIRE.UDP_RECEIVE_BYTES)
            except BlockingIOError:
                break
        self.ready.clear()
        self.assembly.clear()
        self.parts, self.total = self.assembly.parts, 0

    def close(self):
        if not self.closed:
            self.closed = True
            super().close()


class MemoryUART(WIRE.UARTLog):
    """Reuse UART evidence helpers, without a reader thread or credential log file."""

    def __init__(self, port, *, cooperate=None):
        super().__init__(port, path=None)
        self.cooperate = cooperate or (lambda: None)
        self.offset = 0
        self.owner = threading.get_ident()
        self.uart = None

    def __enter__(self):
        import serial

        try:
            self.uart = serial.Serial(port=None, baudrate=self.baud, timeout=0)
            self.uart.port = self.port
            self.uart.dtr = self.uart.rts = False
            self.uart.open()
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def poll(self):
        if threading.get_ident() != self.owner:
            raise TestbenchError("TB_HARDWARE_THREAD_VIOLATION", "INTERNAL")
        if self.uart is None:
            return
        try:
            count = min(self.uart.in_waiting, MAX_UART_POLL_BYTES)
            if count:
                self.data.extend(self.uart.read(count))
                excess = len(self.data) - MAX_UART_BYTES
                if excess > 0:
                    del self.data[:excess]
                    self.offset += excess
        except OSError:
            self.error = "HIL_UART_CAPTURE_ERROR"
            raise TestbenchError("HIL_UART_CAPTURE_ERROR") from None

    def mark(self):
        self.poll()
        return self.offset + len(self.data)

    def text(self, since=0):
        self.poll()
        if since and since < self.offset:
            raise TestbenchError("TB_UART_EVIDENCE_EXPIRED")
        return bytes(self.data[max(0, since - self.offset):]).decode("utf-8", errors="replace")

    def wait_for(self, predicate, since, timeout=WIRE.UART_WAIT_SECONDS,
                 code="HIL_UART_REPLY_TIMEOUT", pump=None):
        return super().wait_for(predicate, since, timeout, code, pump or self.cooperate)

    def reset(self):
        self.cooperate()
        mark = super().reset()
        self.cooperate()
        return mark

    def __exit__(self, exc_type, *exc):
        try:
            super().__exit__(exc_type, *exc)
        finally:
            self.data.clear()


def bluez_client(adapter, cooperate, on_frame):
    """Construct BlueZ on the hardware worker and pump only on that thread."""
    if sys.platform != "linux":
        raise TestbenchError("TB_BLUEZ_REQUIRES_LINUX", "PLATFORM")

    class CooperativeBluez(WIRE.BluezClient):
        def __init__(self):
            super().__init__(adapter)
            self.owner = threading.get_ident()
            self.frames = deque(maxlen=MAX_BLE_FRAMES)
            self.partial_started = None

        def write(self, data):
            if threading.get_ident() != self.owner:
                raise TestbenchError("TB_HARDWARE_THREAD_VIOLATION", "INTERNAL")
            cooperate()
            super().write(data)
            # A synchronous D-Bus call can finish after cancellation. Its reply
            # does not authorize subsequent identity reads, reboot or recovery clear.
            cooperate()

        def pump(self, seconds=0):
            if threading.get_ident() != self.owner:
                raise TestbenchError("TB_HARDWARE_THREAD_VIOLATION", "INTERNAL")
            deadline = time.monotonic() + seconds
            while True:
                cooperate()
                super().pump()
                if self.buffer:
                    if self.partial_started is None:
                        self.partial_started = time.monotonic()
                    elif time.monotonic() - self.partial_started >= FRAME_EXPIRY_SECONDS:
                        self.buffer.clear()
                        self.protocol_errors += 1
                        self.partial_started = None
                else:
                    self.partial_started = None
                if time.monotonic() >= deadline:
                    return
                time.sleep(WORKER_POLL_SECONDS)

        def frame(self, timeout=FRAME_TIMEOUT_SECONDS):
            stamp, data = super().frame(timeout)
            on_frame(stamp, data, "ble")
            return stamp, data

    return CooperativeBluez()
