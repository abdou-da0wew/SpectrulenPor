import unittest
from spectrulenpor_console.network import WifiNetwork, split_escaped


class NetworkParsingTests(unittest.TestCase):
    def test_nmcli_escaped_fields(self):
        encoded = "*:Home" + chr(92) + ":Lab:56:WPA2"
        self.assertEqual(split_escaped(encoded), ["*", "Home:Lab", "56", "WPA2"])

    def test_wifi_record(self):
        network = WifiNetwork("AymanWew", 50, "WPA2", True)
        self.assertEqual(network.ssid, "AymanWew")
        self.assertTrue(network.active)


if __name__ == "__main__":
    unittest.main()
