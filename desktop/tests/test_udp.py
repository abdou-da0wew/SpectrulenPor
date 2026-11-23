import socket
import threading
import time
import unittest
from spectrulenpor_console.protocol import UDP_HEADER, UDP_SAFE_PAYLOAD
from spectrulenpor_console.udp import UdpStreamClient

class UdpAssemblyTests(unittest.TestCase):
    def test_recovers_one_missing_small_frame_fragment(self):
        frame = b"\xff\xd8" + bytes((i * 17) % 251 for i in range(2900)) + b"\xff\xd9"
        chunks = [frame[i:i + UDP_SAFE_PAYLOAD] for i in range(0, len(frame), UDP_SAFE_PAYLOAD)]
        parity = bytearray(UDP_SAFE_PAYLOAD)
        for chunk in chunks:
            for index, value in enumerate(chunk):
                parity[index] ^= value
        received = []
        client = UdpStreamClient(on_frame=lambda data, meta: received.append((data, meta)))
        frame_id = 42
        now = 100.0
        for sequence in (0, 2):
            chunk = chunks[sequence]
            packet = UDP_HEADER.pack(sequence, len(chunks), sequence * UDP_SAFE_PAYLOAD,
                len(chunk), frame_id, len(frame)) + chunk
            client._video(packet, now + sequence * 0.001)
        packet = UDP_HEADER.pack(0x80000000, len(chunks), 0, UDP_SAFE_PAYLOAD,
            frame_id, len(frame)) + bytes(parity)
        client._video(packet, now + 0.01)
        self.assertEqual(len(received), 1)
        self.assertEqual(received[0][0], frame)
        self.assertEqual(received[0][1]["recovered"], 1)
        self.assertEqual(client.metrics()["recovered_fragments"], 1)
        client.close()

    def test_receiver_fps_uses_observed_interval(self):
        client = UdpStreamClient()
        client._frames.extend([10.0, 10.04, 10.08])
        self.assertAlmostEqual(client._fps(10.08), 25.0, places=3)
        client.close()

    def test_late_parity_after_full_data_frame_is_ignored(self):
        received = []
        client = UdpStreamClient(on_frame=lambda data, meta: received.append(data))
        frame = b"\xff\xd8TEST\xff\xd9"
        data_packet = UDP_HEADER.pack(0, 1, 0, len(frame), 100, len(frame)) + frame
        client._video(data_packet, 1.0)
        parity = UDP_HEADER.pack(0x80000000, 1, 0, UDP_SAFE_PAYLOAD,
                                 100, len(frame)) + bytes(UDP_SAFE_PAYLOAD)
        client._video(parity, 1.01)
        self.assertEqual(received, [frame])
        self.assertIsNone(client._frame_id)
        client.close()

    def test_discovers_peer_and_routes_control_over_real_udp_socket(self):
        route = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        route.connect(("1.1.1.1", 80))
        target_ip = route.getsockname()[0]
        route.close()
        server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            server.bind((target_ip, 8888))
        except OSError as exc:
            server.close()
            self.skipTest(f"UDP port 8888 unavailable for integration test: {exc}")
        server.settimeout(2.0)
        connected = threading.Event()
        control_received = threading.Event()
        states = []
        messages = []
        def device_emulator():
            try:
                request, source = server.recvfrom(1024)
                if request != bytes([0x0C]):
                    return
                server.sendto(b"$CMD:keepalive\n", source)
                connected.set()
                command, source = server.recvfrom(1024)
                if command == bytes([0x09]):
                    server.sendto(b"$STATUS:wifi=connected,rssi=-61,channel=5\n", source)
                    control_received.set()
            except socket.timeout:
                pass
        emulator = threading.Thread(target=device_emulator, daemon=True)
        emulator.start()
        client = UdpStreamClient(on_state=states.append, on_message=messages.append)
        try:
            client.start(target_ip)
            self.assertTrue(connected.wait(2.0), "client did not register UDP peer")
            deadline = time.monotonic() + 2
            while client.peer is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(client.peer, (target_ip, 8888))
            client.send_command(0x09)
            self.assertTrue(control_received.wait(2.0), "status command did not reach emulator")
            deadline = time.monotonic() + 1
            while not any(message.startswith("$STATUS:") for message in messages) and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(any(message.startswith("$STATUS:") for message in messages))
            self.assertEqual(client.metrics()["device_status"]["rssi"], -61)
        finally:
            client.close()
            server.close()
            emulator.join(timeout=1)

    def test_rejects_invalid_jpeg(self):
        received = []
        client = UdpStreamClient(on_frame=lambda data, meta: received.append(data))
        frame = b"not-a-jpeg"
        packet = UDP_HEADER.pack(0, 1, 0, len(frame), 1, len(frame)) + frame
        client._video(packet, 1.0)
        self.assertEqual(received, [])
        self.assertEqual(client.metrics()["invalid_packets"], 1)
        client.close()

if __name__ == "__main__":
    unittest.main()
