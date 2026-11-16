"""Compile the actual app_main with host spies; never use hardware or erase NVS."""

import os
import shlex
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


FIRMWARE_ROOT = Path(__file__).resolve().parents[1]
STRICT_FLAGS = ("-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic",
                "-Wconversion", "-Wshadow")
HOST_STUBS = r"""
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "protocol.h"

typedef int esp_err_t;
enum { ESP_OK, ESP_ERR_NVS_NO_FREE_PAGES, ESP_ERR_NVS_NEW_VERSION_FOUND,
       ESP_FAIL, ESP_ERR_INVALID_STATE, ESP_ERR_NVS_NOT_FOUND };
typedef struct { size_t len, width, height; } camera_fb_t;
static struct { firmware_wifi_credentials_t credentials; bool ble_started; } s_app;
static esp_err_t init_result;
static unsigned init_calls, erase_calls, continuation_calls, application_calls, failure_logs;

static void host_log(const char *format, ...)
{
    if (strstr(format, "code=NVS_INIT_FAILED") != NULL) ++failure_logs;
}
#define ESP_LOGI(tag, ...) host_log(__VA_ARGS__)
#define ESP_LOGW(tag, ...) host_log(__VA_ARGS__)
#define ESP_LOGE(tag, ...) host_log(__VA_ARGS__)

esp_err_t nvs_flash_init(void) { ++init_calls; return init_result; }
esp_err_t nvs_flash_erase(void) { ++erase_calls; return ESP_OK; }
static const char *esp_err_to_name(esp_err_t error) { (void)error; return "host-error"; }
static esp_err_t flashlight_init(void) { ++continuation_calls; return ESP_OK; }
static esp_err_t esp_netif_init(void) { ++continuation_calls; return ESP_OK; }
static esp_err_t esp_event_loop_create_default(void) { ++continuation_calls; return ESP_OK; }
static esp_err_t sensors_init(void) { ++continuation_calls; return ESP_FAIL; }
static esp_err_t camera_init(void) { ++continuation_calls; return ESP_OK; }
static camera_fb_t *camera_capture(void) { ++continuation_calls; return NULL; }
static void camera_release(camera_fb_t *fb) { (void)fb; ++continuation_calls; }
static esp_err_t wifi_load_credentials(firmware_wifi_credentials_t *credentials)
{ (void)credentials; ++continuation_calls; return ESP_ERR_NVS_NOT_FOUND; }
bool protocol_wifi_credentials_valid(const firmware_wifi_credentials_t *credentials)
{ (void)credentials; ++continuation_calls; return false; }
static esp_err_t wifi_start_station(const firmware_wifi_credentials_t *credentials)
{ (void)credentials; ++continuation_calls; return ESP_OK; }
static esp_err_t ble_init(void) { ++continuation_calls; return ESP_OK; }
static bool camera_is_ready(void) { ++continuation_calls; return true; }
static bool sensors_available(void) { ++continuation_calls; return false; }
static size_t camera_psram_bytes(void) { ++continuation_calls; return 0; }
static void run_application(void) { ++application_calls; }
"""
HOST_ASSERTIONS = r"""
int main(int argc, char **argv)
{
    if (argc != 2) return EXIT_FAILURE;
    init_result = atoi(argv[1]);
    app_main();
    bool success = init_result == ESP_OK;
    if (init_calls != 1 || erase_calls != 0 ||
        application_calls != (success ? 1U : 0U) ||
        failure_logs != (success ? 0U : 1U) ||
        (success ? continuation_calls == 0 : continuation_calls != 0)) {
        fprintf(stderr, "init=%u erase=%u continuation=%u application=%u failure_logs=%u\n",
                init_calls, erase_calls, continuation_calls, application_calls, failure_logs);
        return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
}
"""


class BootNvsGuardTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        compiler = shlex.split(os.environ.get("CC", "cc"))
        if not compiler or shutil.which(compiler[0]) is None:
            raise RuntimeError("Host C compiler required for the NVS boot regression")
        directory = tempfile.TemporaryDirectory(prefix="spectrulenpor-boot-nvs-")
        cls.addClassCleanup(directory.cleanup)
        source = (FIRMWARE_ROOT / "components/main/main.c").read_text()
        start = source.index("\nvoid app_main(void)")
        harness = Path(directory.name) / "boot_nvs.c"
        cls.binary = harness.with_suffix("")
        harness.write_text(HOST_STUBS + source[start:] + HOST_ASSERTIONS)
        built = subprocess.run(compiler + list(STRICT_FLAGS) + [
            "-I", str(FIRMWARE_ROOT), "-I", str(FIRMWARE_ROOT / "components/protocol"),
            str(harness), "-o", str(cls.binary)], capture_output=True, text=True, timeout=30)
        if built.returncode:
            raise AssertionError("Host boot harness failed to compile:\n" + built.stdout + built.stderr)

    def assert_boot_result(self, result):
        process = subprocess.run([str(self.binary), str(result)], capture_output=True,
                                 text=True, timeout=5)
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def test_success_continues_boot_without_erasing(self):
        self.assert_boot_result(0)

    def test_no_free_pages_preserves_nvs_and_stops_boot(self):
        self.assert_boot_result(1)

    def test_new_version_preserves_nvs_and_stops_boot(self):
        self.assert_boot_result(2)

    def test_other_failure_preserves_nvs_and_stops_boot(self):
        self.assert_boot_result(3)


if __name__ == "__main__":
    unittest.main()
