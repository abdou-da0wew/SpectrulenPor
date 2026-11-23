import unittest
from spectrulenpor_console.protocol import (
    CMD_WIFI_CONFIG_PUT, SPECTRAL_CHANNELS, UDP_HEADER, UDP_PARITY_FLAG,
    decode_video_packet, encode_video_profile, encode_wifi_credentials,
    fec_group_size, parse_spectrum, parse_status_line, VIDEO_PROFILE_AUTO,
)

class ProtocolTests(unittest.TestCase):
    def test_wifi_credentials_payload(self):
        payload = encode_wifi_credentials("Lab WiFi", "password123")
        self.assertEqual(payload, bytes([CMD_WIFI_CONFIG_PUT]) + b"Lab WiFi\0password123\0")

    def test_wifi_credentials_validation(self):
        for ssid, password in (("", "password123"), ("a" * 33, "password123"),
                               ("wifi", "short"), ("wifi\0bad", "password123")):
            with self.subTest(ssid=ssid):
                with self.assertRaises(ValueError):
                    encode_wifi_credentials(ssid, password)

    def test_fec_group_policy(self):
        self.assertEqual([fec_group_size(n) for n in (1, 2, 3, 4, 5)], [1, 1, 1, 1, 4])

    def test_status_parser(self):
        values = parse_status_line("$STATUS:wifi=connected,ip=192.168.1.2,rssi=-62,heap=42000,sensor_valid=1")
        self.assertEqual(values["wifi"], "connected")
        self.assertEqual(values["ip"], "192.168.1.2")
        self.assertEqual(values["rssi"], -62)
        self.assertEqual(values["heap"], 42000)
        self.assertEqual(values["sensor_valid"], 1)

    def test_as7265x_metadata_contains_all_18_ordered_channels(self):
        self.assertEqual(len(SPECTRAL_CHANNELS), 18)
        wavelengths = [item[1] for item in SPECTRAL_CHANNELS]
        self.assertEqual(wavelengths, sorted(wavelengths))
        self.assertEqual(wavelengths[0], 410)
        self.assertEqual(wavelengths[-1], 940)

    def test_parse_full_spectral_snapshot(self):
        raw = "410:10;435:20;460:30;485:40;510:50;535:60;560:70;585:80;610:90;645:100;680:110;705:120;730:130;760:140;810:150;860:160;900:170;940:180"
        values = parse_spectrum(raw)
        self.assertEqual(len(values), 18)
        self.assertEqual(values[410], 10)
        self.assertEqual(values[940], 180)
        self.assertEqual(parse_spectrum("410:12;bad;940:nope;12000:2"), {410: 12})

    def test_video_profile_commands(self):
        self.assertEqual([encode_video_profile(index) for index in range(5)],
                         [bytes([0x0D, index]) for index in range(5)])
        self.assertEqual(encode_video_profile(VIDEO_PROFILE_AUTO), bytes([0x0D, 0xFF]))
        for invalid in (-1, 5, 256, "auto"):
            with self.subTest(profile=invalid):
                with self.assertRaises(ValueError):
                    encode_video_profile(invalid)

    def test_v2_data_header(self):
        payload = b"jpeg"
        datagram = UDP_HEADER.pack(0, 1, 0, len(payload), 7, len(payload)) + payload
        packet = decode_video_packet(datagram)
        self.assertIsNotNone(packet)
        self.assertEqual(packet.frame_id, 7)
        self.assertFalse(packet.parity)

    def test_v2_parity_header(self):
        payload = b"x" * 1448
        datagram = UDP_HEADER.pack(UDP_PARITY_FLAG, 1, 0, len(payload), 8, 10) + payload
        packet = decode_video_packet(datagram)
        self.assertIsNotNone(packet)
        self.assertTrue(packet.parity)
        self.assertEqual(packet.group, 0)

if __name__ == "__main__":
    unittest.main()
