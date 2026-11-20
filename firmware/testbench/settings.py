"""Repository paths and bounded runtime settings for the local testbench."""

from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parent
FIRMWARE_ROOT = PACKAGE_ROOT.parent
REPOSITORY_ROOT = FIRMWARE_ROOT.parent
HIL_ROOT = FIRMWARE_ROOT / "tests"
WEB_ROOT = PACKAGE_ROOT / "web"
LOCALIZATION_ROOT = REPOSITORY_ROOT / "lib" / "l10n"

DEFAULT_ADAPTER = "hci0"
DEFAULT_PORT = 8765
LOOPBACK_HOST = "127.0.0.1"
PROFILES = ("smoke", "full", "mobile-flow", "missing-ap", "soak")
MAX_JSON_BYTES = 4096
MAX_JSON_DEPTH = 16
MAX_HTTP_FRAME_BYTES = 512 * 1024
MAX_ASSET_BYTES = 4 * 1024 * 1024
MAX_REQUEST_PATH_BYTES = 2048
MAX_HTTP_CLIENTS = 16
HTTP_TIMEOUT_SECONDS = 5
HTTP_POLL_SECONDS = 0.2
WORKER_POLL_SECONDS = 0.01
LINK_CHECK_SECONDS = 1
UART_OPEN_OBSERVE_SECONDS = 3
FRAME_TIMEOUT_SECONDS = 12
FRAME_EXPIRY_SECONDS = 60
QUIET_SECONDS = 2.2
FPS_WINDOW_SECONDS = 5
MAX_EVENTS = 100
MAX_RECORDS = 200
MAX_UART_BYTES = 2 * 1024 * 1024
MAX_UART_POLL_BYTES = 65536
MAX_IMAGE_DIMENSION = 4096
WIFI_MAX_SSID_BYTES = 32
WIFI_MAX_PASSWORD_BYTES = 64
WIFI_MIN_PASSWORD_BYTES = 8
MAX_PUMP_DATAGRAMS = 64
MAX_BLE_FRAMES = 4
MIN_SOAK_SECONDS = 1
MAX_SOAK_SECONDS = 3600
DEFAULT_SOAK_SECONDS = 60
VIEW_POLL_SECONDS = 0.05
VIEW_TITLE = "SpectruLenPor Testbench"
TOKEN_HEADER = "X-Testbench-Token"
SSID_ENV = "SPECTRULENPOR_TEST_SSID"
PASSWORD_ENV = "SPECTRULENPOR_TEST_PASSWORD"
STATIC_FILES = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/index.html": ("index.html", "text/html; charset=utf-8"),
    "/app.js": ("app.js", "text/javascript; charset=utf-8"),
    "/styles.css": ("styles.css", "text/css; charset=utf-8"),
    "/style.css": ("style.css", "text/css; charset=utf-8"),
}

CMD_UDP_KEEPALIVE = 0x0C
