"""Protect project attribution and BLE/UDP identity contracts from drift."""

import json
import re
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

# Project author: Malak Adel Sayed Hassan.
# Original application/firmware code author: Abdou (عبد الرحمن أيمن محمد).
ROOT = Path(__file__).resolve().parents[3]
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"


class AttributionMetadataTests(unittest.TestCase):
    def test_repository_and_firmware_metadata_have_the_same_owners(self):
        project = json.loads((ROOT / "PROJECT_METADATA.json").read_text(encoding="utf-8"))
        firmware = json.loads((ROOT / "firmware/manifest.json").read_text(encoding="utf-8"))

        self.assertEqual(project["project"]["author"]["name"], "Malak Adel Sayed Hassan")
        self.assertEqual(project["software"]["developer"]["name"], "Abdou")
        self.assertEqual(project["software"]["developer"]["displayName"], "Abdou")
        self.assertEqual(project["software"]["developer"]["github"], "abdou-da0wew")
        self.assertEqual(project["software"]["developer"]["nameArabic"], "عبد الرحمن أيمن محمد")
        self.assertIn("written by Abdou", project["software"]["codeAuthorship"]["statement"])
        self.assertEqual(firmware["project"]["projectAuthor"]["name"], "Malak Adel Sayed Hassan")
        self.assertEqual(firmware["creator"]["name"], "Abdou")
        self.assertEqual(firmware["creator"]["displayName"], "Abdou")
        self.assertEqual(firmware["maintainers"][0]["github"], "abdou-da0wew")

    def test_ble_scan_response_identifies_developer_and_project_author(self):
        source = (ROOT / "firmware/components/ble/ble.c").read_text(encoding="utf-8")
        match = re.search(r"identity_service_data\[\]\s*=\s*\{(.*?)\};", source, re.S)
        self.assertIsNotNone(match)

        body = match.group(1)
        uuid_bytes = bytes(int(value, 16) for value in re.findall(r"0x([0-9A-Fa-f]{2})", body))
        text_bytes = "".join(re.findall(r"'([^']+)'", body)).encode("ascii")
        payload = uuid_bytes + text_bytes

        self.assertEqual(payload, b"\xE0\xFFDEV:Abdou;PROJECT:Malak")
        self.assertLessEqual(len(payload) + 2, 31)
        self.assertIn("scan_response.svc_data_uuid16 = identity_service_data;", source)
        self.assertIn("scan_response.svc_data_uuid16_len = (uint8_t)sizeof(identity_service_data);", source)
        self.assertIn("ble_gap_adv_rsp_set_fields(&scan_response)", source)
        self.assertIn('#define BLE_DEV_NAME      "SpectruLenPor-ESP32"', (ROOT / "firmware/config.h").read_text())

    def test_udp_v2_header_remains_a_fixed_binary_contract(self):
        config = (ROOT / "firmware/config.h").read_text(encoding="utf-8")
        dart = (ROOT / "lib/services/wifi_udp_video_service.dart").read_text(encoding="utf-8")
        protocol = (ROOT / "firmware/components/protocol/protocol.h").read_text(encoding="utf-8")

        self.assertRegex(config, r"#define UDP_HEADER_LEN\s+24U")
        self.assertRegex(config, r"#define UDP_PAYLOAD_BYTES\s+1200U")
        self.assertIn("static const int udpHeaderLen = 24;", dart)
        self.assertIn("static const int payloadBytes = 1200;", dart)
        self.assertIn("frame_id, frame_size", protocol)
        self.assertIn("no text metadata", protocol)

    def test_android_package_carries_project_and_developer_metadata(self):
        manifest = ET.parse(ROOT / "android/app/src/main/AndroidManifest.xml").getroot()
        application = manifest.find("application")
        values = {
            node.attrib.get(ANDROID_NS + "name"): node.attrib.get(ANDROID_NS + "value")
            for node in application.findall("meta-data")
        }

        self.assertEqual(values["com.spectrulenpor.PROJECT_AUTHOR"], "Malak Adel Sayed Hassan")
        self.assertEqual(values["com.spectrulenpor.SOFTWARE_DEVELOPER"], "Abdou")
        self.assertEqual(values["com.spectrulenpor.DEVELOPER_DISPLAY_NAME"], "Abdou")
        self.assertEqual(values["com.spectrulenpor.DEVELOPER_GITHUB"], "https://github.com/abdou-da0wew")
        self.assertEqual(values["com.spectrulenpor.DEVELOPER_NAME_AR"], "عبد الرحمن أيمن محمد")
        self.assertEqual(values["com.spectrulenpor.CODE_AUTHORSHIP"], "All original application and firmware code authored by Abdou")


if __name__ == "__main__":
    unittest.main()
