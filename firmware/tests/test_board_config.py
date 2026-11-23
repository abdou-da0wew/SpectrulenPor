"""Keep tracked AI-Thinker settings consistent with the firmware build defaults."""

import re
import unittest
from pathlib import Path


FIRMWARE_ROOT = Path(__file__).resolve().parents[1]
SDKCONFIG_PATH = FIRMWARE_ROOT / "sdkconfig"
DEFAULTS_PATH = FIRMWARE_ROOT / "sdkconfig.defaults"
PARTITIONS_PATH = FIRMWARE_ROOT / "partitions.csv"
CONFIG_HEADER_PATH = FIRMWARE_ROOT / "config.h"
ENABLED = "y"
DISABLED = "n"
BOARD_SELECTIONS = (
    "CONFIG_IDF_TARGET",
    "CONFIG_ESPTOOLPY_FLASHMODE_DIO",
    "CONFIG_ESPTOOLPY_FLASHFREQ_40M",
    "CONFIG_ESPTOOLPY_FLASHSIZE_4MB",
    "CONFIG_PARTITION_TABLE_CUSTOM",
    "CONFIG_PARTITION_TABLE_CUSTOM_FILENAME",
    "CONFIG_ESP_DEFAULT_CPU_FREQ_MHZ_240",
    "CONFIG_ESP_MAIN_TASK_STACK_SIZE",
    "CONFIG_FREERTOS_HZ",
)
PSRAM_SELECTIONS = (
    "CONFIG_SPIRAM",
    "CONFIG_SPIRAM_BOOT_INIT",
    "CONFIG_SPIRAM_TYPE_AUTO",
    "CONFIG_SPIRAM_SPEED_40M",
    "CONFIG_SPIRAM_USE_MALLOC",
    "CONFIG_SPIRAM_IGNORE_NOTFOUND",
    "CONFIG_SPIRAM_MALLOC_RESERVE_INTERNAL",
)
DRIVER_SELECTIONS = (
    "CONFIG_BT_ENABLED",
    "CONFIG_BT_NIMBLE_ENABLED",
    "CONFIG_BT_BLUEDROID_ENABLED",
    "CONFIG_SCCB_HARDWARE_I2C_DRIVER_NEW",
    "CONFIG_SCCB_HARDWARE_I2C_PORT0",
    "CONFIG_OV2640_SUPPORT",
    "CONFIG_CAMERA_CORE1",
)
WIFI_SELECTIONS = (
    "CONFIG_ESP_WIFI_TASK_PINNED_TO_CORE_0",
    "CONFIG_ESP_WIFI_STATIC_TX_BUFFER",
    "CONFIG_ESP_WIFI_STATIC_TX_BUFFER_NUM",
    "CONFIG_ESP_WIFI_IRAM_OPT",
    "CONFIG_ESP_WIFI_RX_IRAM_OPT",
    "CONFIG_ESP_WIFI_AMPDU_TX_ENABLED",
)


def config_values(path):
    result = {}
    for line in path.read_text().splitlines():
        assignment = re.fullmatch(r"(CONFIG_[A-Z0-9_]+)=(.*)", line)
        disabled = re.fullmatch(r"# (CONFIG_[A-Z0-9_]+) is not set", line)
        if assignment:
            key, value = assignment.groups()
        elif disabled:
            key, value = disabled.group(1), DISABLED
        else:
            continue
        if key in result:
            raise ValueError(f"Duplicate configuration key: {key}")
        result[key] = value
    return result


class BoardConfigTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tracked = config_values(SDKCONFIG_PATH)
        cls.defaults = config_values(DEFAULTS_PATH)

    def assert_defaults(self, keys):
        for key in keys:
            with self.subTest(key=key):
                self.assertIn(key, self.defaults)
                self.assertEqual(self.tracked.get(key), self.defaults[key])

    def test_board_and_partition_selections_match_defaults(self):
        self.assert_defaults(BOARD_SELECTIONS)
        self.assertTrue(PARTITIONS_PATH.is_file())
        self.assertEqual(self.tracked["CONFIG_PARTITION_TABLE_FILENAME"],
                         f'"{PARTITIONS_PATH.name}"')
        self.assertEqual(self.tracked["CONFIG_PARTITION_TABLE_SINGLE_APP"], DISABLED)

    def test_psram_support_and_boot_policy_match_defaults(self):
        self.assert_defaults(PSRAM_SELECTIONS)
        self.assertEqual(self.tracked["CONFIG_SPIRAM"], ENABLED)

    def test_ble_camera_and_i2c_drivers_match_defaults(self):
        self.assert_defaults(DRIVER_SELECTIONS)

    def test_wifi_buffer_and_core_settings_match_defaults(self):
        self.assert_defaults(WIFI_SELECTIONS)

    def test_weak_link_udp_pacing_keeps_ampdu_aggregation_enabled(self):
        header = CONFIG_HEADER_PATH.read_text(encoding="utf-8")
        self.assertEqual(self.tracked["CONFIG_ESP_WIFI_AMPDU_TX_ENABLED"], ENABLED)
        self.assertEqual(self.tracked["CONFIG_ESP_WIFI_STATIC_TX_BUFFER_NUM"], "40")
        self.assertRegex(header, r"#define UDP_PACKET_PACE_MINIMAL_MS 2U")
        self.assertRegex(header, r"#define UDP_MTU_SAFE\s+1472U")
        self.assertRegex(header, r"#define UDP_HEADER_LEN\s+24U")
        self.assertRegex(header, r"#define UDP_PAYLOAD_BYTES\s+1448U")
        self.assertRegex(header, r"#define UDP_QUALITY_MINIMAL\s+40")
        self.assertRegex(header, r"#define UDP_RSSI_ULTRA_DBM\s+\(-82\)")
        self.assertRegex(header, r"#define UDP_PACKET_PACE_ULTRA_MS 1U")
        self.assertRegex(header, r"#define UDP_PACKET_PACE_LOW_MS 2U")
        self.assertRegex(header, r"#define UDP_INTERVAL_ULTRA_MS\s+0U")
        self.assertRegex(header, r"#define UDP_FRAME_BUDGET_MS\s+50U")
        self.assertNotIn("UDP_FRAME_BUDGET_SVGA_MS", header)
        self.assertRegex(header, r"#define UDP_QUALITY_ULTRA\s+40")
        self.assertRegex(header, r"#define UDP_INTERVAL_MINIMAL_MS\s+0")
        self.assertRegex(header, r"#define WIFI_BLE_RECOVERY_DELAY_MS 60000U")

    def test_camera_profile_switch_is_bounded_and_uses_latest_frame_queue(self):
        config = (FIRMWARE_ROOT / "config.h").read_text(encoding="utf-8")
        camera = (FIRMWARE_ROOT / "components/ov2640/camera.c").read_text(encoding="utf-8")
        self.assertRegex(config, r"#define CAMERA_PROFILE_SETTLE_MS 150U")
        self.assertIn("CAMERA_GRAB_LATEST", (FIRMWARE_ROOT / "components/ov2640/camera.c").read_text(encoding="utf-8") + (FIRMWARE_ROOT / "components/ov2640/camera.h").read_text(encoding="utf-8"))
        self.assertIn("vTaskDelay(pdMS_TO_TICKS(CAMERA_PROFILE_SETTLE_MS))", camera)
        self.assertNotIn("for (size_t i = 0; i <= s_frame_buffers; ++i)", camera)
        self.assertIn("FRAMESIZE_QQVGA", camera)
        main = (FIRMWARE_ROOT / "components/main/main.c").read_text(encoding="utf-8")
        self.assertIn("rssi < UDP_RSSI_ULTRA_DBM", main)
        self.assertIn("target_size = FRAMESIZE_QQVGA", main)

    def test_status_snapshot_exposes_radio_and_spectral_diagnostics(self):
        wifi = (FIRMWARE_ROOT / "components/wifi/wifi.c").read_text(encoding="utf-8")
        wifi_header = (FIRMWARE_ROOT / "components/wifi/wifi.h").read_text(encoding="utf-8")
        main = (FIRMWARE_ROOT / "components/main/main.c").read_text(encoding="utf-8")
        self.assertIn("int wifi_channel_number(void)", wifi_header)
        self.assertIn("ap_info.primary", wifi)
        self.assertIn("rssi=%d,channel=%d,profile=%u", main)
        self.assertIn("sensor_valid=%d,sensor_410=%u,sensor_940=%u,spectrum=%s", main)
        self.assertIn("sensors_read_spectrum(&sensor_reading)", main)
        self.assertIn("capture_ms=%", main)
        self.assertIn("send_ms=%", main)
        self.assertIn("frame_ms=%", main)
        self.assertIn("pace_ms=%", main)
        self.assertIn("interval_ms=%", main)
        self.assertIn("AS7265X_CHANNEL_COUNT", main)
        sensor = (FIRMWARE_ROOT / "components/sensors/sensors.c").read_text(encoding="utf-8")
        self.assertIn("AS7265X_DEVICE_AS72653", sensor)
        self.assertIn("AS7265X_DEVICE_AS72652", sensor)
        self.assertIn("AS7265X_DEVICE_AS72651", sensor)
        self.assertIn("read_selected_temperature", sensor)
        self.assertRegex((FIRMWARE_ROOT / "config.h").read_text(),
                         r"#define STATUS_TEXT_CAPACITY\s+768")

    def test_udp_video_profile_override_is_available(self):
        config = (FIRMWARE_ROOT / "config.h").read_text(encoding="utf-8")
        protocol = (FIRMWARE_ROOT / "components/protocol/protocol.c").read_text(encoding="utf-8")
        main = (FIRMWARE_ROOT / "components/main/main.c").read_text(encoding="utf-8")
        self.assertRegex(config, r"#define CMD_SET_VIDEO_PROFILE\s+0x0D")
        self.assertIn("data[1] != UINT8_MAX && data[1] > 4U", protocol)
        self.assertIn("code == CMD_SET_VIDEO_PROFILE", protocol)
        self.assertIn("s_app.udp_profile_manual", main)
        self.assertIn("? s_app.udp_profile", main)
        self.assertIn("VIDEO_PROFILE_REQUIRES_UDP", main)
        self.assertIn("manual_profile=%d", main)

    def test_wifi_leaves_phy_rate_adaptive_for_weak_links(self):
        wifi = (FIRMWARE_ROOT / "components/wifi/wifi.c").read_text(encoding="utf-8")
        self.assertNotIn("esp_wifi_config_80211_tx_rate", wifi)
        self.assertIn("esp_wifi_set_max_tx_power(84)", wifi)
        self.assertIn("esp_wifi_set_bandwidth(WIFI_IF_STA, WIFI_BW_HT20)", wifi)


if __name__ == "__main__":
    unittest.main()
