"""Keep tracked AI-Thinker settings consistent with the firmware build defaults."""

import re
import unittest
from pathlib import Path


FIRMWARE_ROOT = Path(__file__).resolve().parents[1]
SDKCONFIG_PATH = FIRMWARE_ROOT / "sdkconfig"
DEFAULTS_PATH = FIRMWARE_ROOT / "sdkconfig.defaults"
PARTITIONS_PATH = FIRMWARE_ROOT / "partitions.csv"
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


if __name__ == "__main__":
    unittest.main()
