"""Protect project attribution and BLE/UDP identity contracts from drift."""

import json
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

# Project author: Malak Adel Sayed Hassan.
# Original application/firmware code author: Abdoul-Rahman Ayman (GitHub: abdou-da0wew).
ROOT = Path(__file__).resolve().parents[3]
ANDROID_NS = "{http://schemas.android.com/apk/res/android}"


def macro_value(source, name):
    prefix = f"#define {name} "
    for line in source.splitlines():
        if line.startswith(prefix):
            return line[len(prefix):].split("/*", 1)[0].split("//", 1)[0].strip()
    raise AssertionError(f"Missing macro: {name}")


class AttributionMetadataTests(unittest.TestCase):
    def test_repository_and_firmware_metadata_have_the_same_owners(self):
        project = json.loads((ROOT / "PROJECT_METADATA.json").read_text(encoding="utf-8"))
        firmware = json.loads((ROOT / "firmware/manifest.json").read_text(encoding="utf-8"))

        developer = project["software"]["developer"]
        self.assertEqual(project["project"]["author"]["name"], "Malak Adel Sayed Hassan")
        self.assertEqual(developer["name"], "Abdoul-Rahman Ayman")
        self.assertEqual(developer["displayName"], "Abdoul-Rahman Ayman")
        self.assertEqual(developer["github"], "abdou-da0wew")
        self.assertNotIn("nameArabic", developer)
        self.assertIn("written by Abdoul-Rahman Ayman", project["software"]["codeAuthorship"]["statement"])
        self.assertIn("abdou-da0wew", project["software"]["codeAuthorship"]["statement"])

        self.assertEqual(firmware["project"]["projectAuthor"]["name"], "Malak Adel Sayed Hassan")
        self.assertEqual(firmware["creator"]["name"], "Abdoul-Rahman Ayman")
        self.assertEqual(firmware["creator"]["displayName"], "Abdoul-Rahman Ayman")
        self.assertEqual(firmware["maintainers"][0]["name"], "Abdoul-Rahman Ayman")
        self.assertEqual(firmware["maintainers"][0]["github"], "abdou-da0wew")

        expected_identity = "DEV:abdou-da0wew;P:Malak"
        self.assertEqual(project["deviceIdentity"]["ble"]["value"], expected_identity)
        self.assertEqual(firmware["deviceIdentity"]["bleScanResponse"]["serviceData"], expected_identity)

        config = (ROOT / "firmware/config.h").read_text(encoding="utf-8")
        self.assertEqual(macro_value(config, "FIRMWARE_DEVELOPER_NAME"), '"Abdoul-Rahman Ayman"')
        self.assertEqual(macro_value(config, "FIRMWARE_DEVELOPER_DISPLAY"), '"Abdoul-Rahman Ayman"')
        main_source = (ROOT / "firmware/components/main/main.c").read_text(encoding="utf-8")
        self.assertIn("FIRMWARE_DEVELOPER_NAME);", main_source)

    def test_ble_scan_response_identifies_developer_and_project_author(self):
        source = (ROOT / "firmware/components/ble/ble.c").read_text(encoding="utf-8")
        marker = "static uint8_t identity_service_data[] = {"
        self.assertIn(marker, source)
        body = source.split(marker, 1)[1].split("};", 1)[0]

        payload_parts = []
        for item in body.split(","):
            item = item.strip()
            if not item:
                continue
            if item.startswith("0x"):
                payload_parts.append(int(item, 16))
            else:
                payload_parts.extend(item.strip("'").encode("ascii"))
        payload = bytes(payload_parts)

        expected_payload = bytes([0xE0, 0xFF]) + b"DEV:abdou-da0wew;P:Malak"
        self.assertEqual(payload, expected_payload)
        self.assertLessEqual(len(payload) + 2, 31)
        self.assertIn("scan_response.svc_data_uuid16 = identity_service_data;", source)
        self.assertIn("scan_response.svc_data_uuid16_len = (uint8_t)sizeof(identity_service_data);", source)
        self.assertIn("ble_gap_adv_rsp_set_fields(&scan_response)", source)

        config = (ROOT / "firmware/config.h").read_text(encoding="utf-8")
        self.assertIn('#define BLE_DEV_NAME      "SpectruLenPor-ESP32"', config)

    def test_udp_v2_header_remains_a_fixed_binary_contract(self):
        config = (ROOT / "firmware/config.h").read_text(encoding="utf-8")
        dart = (ROOT / "lib/services/wifi_udp_video_service.dart").read_text(encoding="utf-8")
        protocol = (ROOT / "firmware/components/protocol/protocol.h").read_text(encoding="utf-8")

        self.assertEqual(macro_value(config, "UDP_HEADER_LEN"), "24U")
        self.assertEqual(macro_value(config, "UDP_PAYLOAD_BYTES"), "1448U")
        self.assertIn("static const int udpHeaderLen = 24;", dart)
        self.assertIn("static const int payloadBytes = 1448;", dart)
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
        self.assertEqual(values["com.spectrulenpor.SOFTWARE_DEVELOPER"], "Abdoul-Rahman Ayman")
        self.assertEqual(values["com.spectrulenpor.DEVELOPER_DISPLAY_NAME"], "Abdoul-Rahman Ayman")
        self.assertEqual(values["com.spectrulenpor.DEVELOPER_GITHUB"], "https://github.com/abdou-da0wew")
        self.assertNotIn("com.spectrulenpor.DEVELOPER_NAME_AR", values)
        self.assertEqual(
            values["com.spectrulenpor.CODE_AUTHORSHIP"],
            "All original application and firmware code authored by Abdoul-Rahman Ayman (GitHub: abdou-da0wew)",
        )

    def test_developer_attribution_metadata_uses_latin_characters(self):
        paths = [
            ROOT / "PROJECT_METADATA.json",
            ROOT / "firmware/manifest.json",
            ROOT / "firmware/config.h",
            ROOT / "firmware/components/ble/ble.c",
            ROOT / "firmware/components/main/main.c",
            ROOT / "android/app/src/main/AndroidManifest.xml",
        ]
        for path in paths:
            content = path.read_text(encoding="utf-8")
            with self.subTest(path=path.relative_to(ROOT)):
                self.assertFalse(any(0x0600 <= ord(char) <= 0x06FF for char in content))

    def test_commit_hook_preserves_diveeagent_coauthor_trailer(self):
        hook = (ROOT / ".githooks/commit-msg").read_text(encoding="utf-8")
        self.assertIn("coauthor_email='270451464+DiveeAgent@users.noreply.github.com'", hook)
        self.assertIn("Co-authored-by: DiveeAgent <$coauthor_email>", hook)
        self.assertIn("git interpret-trailers", hook)


if __name__ == "__main__":
    unittest.main()
