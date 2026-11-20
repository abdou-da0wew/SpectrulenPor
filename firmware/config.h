#ifndef SPECTRULENPOR_CONFIG_H
#define SPECTRULENPOR_CONFIG_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/* ===========================================================================
 *  SpectruLenPor ESP32-CAM firmware (ESP-IDF 5.x)
 *  Architecture: BLE-first setup, then WiFi-only operation.
 *
 *  Boot flow:
 *    1. ESP boots → check NVS for saved WiFi credentials
 *    2. If credentials exist → connect to WiFi, disable BLE, enter WiFi mode
 *    3. If no credentials → start BLE in setup mode, wait for mobile app
 *    4. Mobile app connects via BLE with pairing code "11111"
 *    5. Mobile sends WiFi SSID/password via BLE
 *    6. ESP saves WiFi credentials to NVS without starting WiFi
 *    7. ESP sends back its own MAC address + hostname to mobile via BLE
 *    8. Mobile app sends reboot command via BLE
 *    9. ESP reboots → connects to WiFi without initializing BLE
 *   10. Connection failure never erases credentials or enables BLE
 * ========================================================================== */

/* ---------------------------------------------------------------------------
 *  Hardware pins — AI-Thinker ESP32-CAM
 * -------------------------------------------------------------------------- */
#define PIN_CAM_PWDN      32
#define PIN_CAM_RESET     -1
#define PIN_CAM_XCLK       0
#define PIN_CAM_SIOD      26
#define PIN_CAM_SIOC      27
#define PIN_CAM_Y9        35
#define PIN_CAM_Y8        34
#define PIN_CAM_Y7        39
#define PIN_CAM_Y6        36
#define PIN_CAM_Y5        21
#define PIN_CAM_Y4        19
#define PIN_CAM_Y3        18
#define PIN_CAM_Y2         5
#define PIN_CAM_VSYNC     25
#define PIN_CAM_HREF      23
#define PIN_CAM_PCLK      22

#define PIN_FLASH_LED      4   /* onboard white flash LED                */
#define PIN_AS72655_SDA   13
#define PIN_AS72655_SCL   14

/* ---------------------------------------------------------------------------
 *  OV2640 sensor settings
 * -------------------------------------------------------------------------- */
#define CAM_FRAME_SIZE    FRAMESIZE_XGA
#define CAM_BLE_FRAME_SIZE FRAMESIZE_QVGA
#define CAM_JPEG_QUALITY  30
#define CAM_BLE_JPEG_QUALITY 16
#define CAM_XCLK_HZ       20000000
#define CAM_FRAME_BUFFERS 2
#define CAM_SETTINGS_NEUTRAL 0
#define CAM_GAIN_CEILING GAINCEILING_2X
#define MAX_FRAME_BYTES  (512U * 1024U)
#define JPEG_MIN_BYTES   4U
#define JPEG_MARKER_PREFIX 0xFFU
#define JPEG_MARKER_SOI  0xD8U
#define JPEG_MARKER_EOI  0xD9U

/* ---------------------------------------------------------------------------
 *  AS7265x spectral triad on I2C1
 * -------------------------------------------------------------------------- */
#define AS7265x_I2C_NUM   I2C_NUM_1
#define AS7265x_I2C_ADDR  0x49
#define AS7265x_I2C_FREQ  100000
#define SENSOR_I2C_TIMEOUT_MS 100
#define SENSOR_VIRTUAL_TIMEOUT_MS 250
#define SENSOR_POLL_INTERVAL_MS 5
#define SENSOR_INTEGRATION_CYCLES 49
#define SENSOR_MEASUREMENT_TIMEOUT_MS 1000

/* ---------------------------------------------------------------------------
 *  BLE GATT contract (mirrors lib/services/bluetooth_camera_service.dart)
 *  BLE is ONLY used for initial WiFi setup. After WiFi is configured and
 *  the device reboots, BLE is disabled and WiFi takes over completely.
 * -------------------------------------------------------------------------- */
#define BLE_SVC_UUID      "0000ffe0-0000-1000-8000-00805f9b34fb"
#define BLE_TX_CHAR_UUID  "0000ffe1-0000-1000-8000-00805f9b34fb" /* notify */
#define BLE_RX_CHAR_UUID  "0000ffe2-0000-1000-8000-00805f9b34fb" /* write  */
#define BLE_DEV_NAME      "SpectruLenPor-ESP32"
#define BLE_SVC_UUID16    0xFFE0
#define BLE_TX_UUID16     0xFFE1
#define BLE_RX_UUID16     0xFFE2

/* Pairing code required before WiFi config can be sent over BLE */
#define BLE_PAIRING_CODE  "11111"
#define BLE_PAIRING_CODE_LEN 5
_Static_assert(sizeof(BLE_PAIRING_CODE) - 1U == BLE_PAIRING_CODE_LEN,
               "Pairing code length must match its configured bytes");

#define BLE_PREFERRED_MTU 517
#define BLE_COMMAND_QUEUE_LENGTH 16
#define BLE_HOST_STACK_BYTES 4096
#define BLE_HOST_PRIORITY 5
#define BLE_NOTIFY_RETRY_MS 3
#define BLE_NOTIFY_TIMEOUT_MS 2000
#define BLE_NOTIFY_PACE_MS 3
#define BLE_CONNECT_TIMEOUT_MS 30000

/* ---------------------------------------------------------------------------
 *  Command bytes (BLE setup-only or UDP runtime control; see whitelist)
 * -------------------------------------------------------------------------- */
#define CMD_STREAM_OFF          0x00
#define CMD_STREAM_ON           0x01
#define CMD_SINGLE_FRAME        0x02
#define CMD_FLASH_ON            0x03
#define CMD_FLASH_OFF           0x04
#define CMD_RESTART             0x05
#define CMD_SHUTDOWN            0x06
#define CMD_WIFI_CONFIG_PUT     0x07   /* payload: "SSID\0PASS\0" */
#define CMD_WIFI_CONFIG_GET     0x08   /* reply: current SSID over TX */
#define CMD_CONNECTION_STATUS   0x09   /* reply: connection+WiFi status */
#define CMD_BLE_PAIR            0x0A   /* payload: pairing code string */
#define CMD_REBOOT              0x0B   /* reboot ESP after WiFi setup complete */
#define CMD_UDP_KEEPALIVE        0x0C   /* refresh current UDP peer without resuming */

/* ---------------------------------------------------------------------------
 *  Stream / telemetry timing
 * -------------------------------------------------------------------------- */
#define STREAM_INTERVAL_MS      100   /* UDP video ~10 fps SVGA */
#define BLE_STREAM_INTERVAL_MS  1000
#define TELEMETRY_INTERVAL_MS   500   /* 2 Hz UV/IR over BLE */
#define STATUS_INTERVAL_MS      2000
#define MAIN_POLL_INTERVAL_MS   10
#define MAIN_STREAM_POLL_INTERVAL_MS 1U
#define RESTART_ACK_DELAY_MS    200
#define BLE_CHUNK_SIZE          500   /* <= MTU-3 */
#define STATUS_TEXT_CAPACITY    256
#define TELEMETRY_TEXT_CAPACITY 64
#define IPV4_TEXT_CAPACITY      16
#define FIRMWARE_VERSION        "3.2.0"

/* Project authorship and repository metadata. */
#define FIRMWARE_AUTHOR_NAME    "Abdoul-Rahman Ayman"
#define FIRMWARE_AUTHOR_GITHUB  "abdou-da0wew"
#define FIRMWARE_AUTHOR_URL     "https://github.com/abdou-da0wew"

/* ---------------------------------------------------------------------------
 *  WiFi / UDP video (WiFi-only mode after BLE setup)
 * -------------------------------------------------------------------------- */
#define UDP_VIDEO_PORT     8888
#define UDP_MTU_SAFE       1280U
#define UDP_HEADER_LEN     24U        /* six little-endian u32 fields */
#define UDP_PAYLOAD_BYTES  1200U      /* 802.11/1500-byte-IP-MTU-safe JPEG chunks */
#define UDP_FEC_GROUP_SIZE 4U
#define UDP_PARITY_SEQUENCE_FLAG 0x80000000UL
#define WIFI_HOSTNAME      "spectrulenpor-esp32"
#define WIFI_RETRY_INTERVAL_MS  10000
#define WIFI_MAX_RETRIES     20
#define WIFI_CONNECT_TIMEOUT_MS 30000
#define WIFI_BOOT_ASSOCIATION_WAIT_MS 5000
#define WIFI_BLE_RECOVERY_DELAY_MS 30000U
#define WIFI_SCAN_RESULT_CAPACITY 16
#define WIFI_MIN_RSSI_DBM (-127)
#define WIFI_SSID_MAX_BYTES 32U
#define WIFI_PASSWORD_MAX_BYTES 64U
#define WIFI_SSID_CAPACITY (WIFI_SSID_MAX_BYTES + 1U)
#define WIFI_PASSWORD_CAPACITY (WIFI_PASSWORD_MAX_BYTES + 1U)
#define WIFI_MIN_PASSPHRASE_BYTES 8U

/* WiFi credentials are stored together as a blob under WIFI_NVS_KEY_SSID. */
#define WIFI_NVS_NAMESPACE "spectrulenpor"
#define WIFI_NVS_KEY_SSID       "wifi_ssid"
#define WIFI_NVS_KEY_PASSWORD   "wifi_pass"
#define WIFI_NVS_KEY_MOBILE_MAC "mob_mac"
#define WIFI_NVS_KEY_MOBILE_NAME "mob_name"
#define WIFI_NVS_KEY_ESP_MAC    "esp_mac"
#define WIFI_NVS_KEY_ESP_NAME   "esp_name"
#define WIFI_NVS_KEY_CONFIGURED "wifi_configured"

/* Command max size including WiFi config payload */
#define COMMAND_MAX_BYTES (1U + WIFI_SSID_CAPACITY + WIFI_PASSWORD_CAPACITY)
#define UDP_PACKET_PACE_HIGH_MS 1U
#define UDP_PACKET_PACE_MEDIUM_MS 2U
#define UDP_PACKET_PACE_LOW_MS 5U
#define UDP_PACKET_PACE_MINIMAL_MS 8U
#define UDP_SEND_RETRY_DELAY_MS 5U
#define UDP_SEND_RETRY_MAX_DELAY_MS 32U
#define UDP_SEND_MAX_ATTEMPTS 16U
#define UDP_CONTROL_SEND_ATTEMPTS 8U
#define UDP_CONTROL_RETRY_DELAY_MS 5U
#define UDP_CONTROL_DUPLICATE_DELAY_MS 12U
#define UDP_FRAME_SEND_TIMEOUT_MS 3000
#define UDP_FRAME_BUDGET_MS 50U
#define UDP_FRAME_BUDGET_SVGA_MS 40U
#define UDP_PROFILE_HOLD_MS 15000U
#define UDP_RSSI_HIGH_DBM       (-60)
#define UDP_RSSI_MEDIUM_DBM    (-66)
#define UDP_RSSI_LOW_DBM       (-70)
#define UDP_QUALITY_HIGH         20
#define UDP_QUALITY_MEDIUM       24
#define UDP_QUALITY_LOW          28
#define UDP_QUALITY_MINIMAL      34
#define UDP_INTERVAL_HIGH_MS      0
#define UDP_INTERVAL_MEDIUM_MS    0
#define UDP_INTERVAL_LOW_MS      10
#define UDP_INTERVAL_MINIMAL_MS  25
#define UDP_PEER_SETTLE_MS 250
#define UDP_POLL_MAX_PACKETS 16
#define UDP_RCVBUF_BYTES 262144

/* ---------------------------------------------------------------------------
 *  Packet header for UDP video (16 bytes)
 * -------------------------------------------------------------------------- */
typedef struct __attribute__((packed)) {
    uint32_t seq;        /* packet sequence within this frame   */
    uint32_t total;      /* total packets in this frame         */
    uint32_t offset;     /* byte offset of this chunk in JPEG   */
    uint32_t size;       /* size of this chunk payload          */
    uint32_t frame_id;   /* increments once per captured JPEG   */
    uint32_t frame_size; /* full JPEG byte length                */
} udp_frame_hdr_t;

#endif /* SPECTRULENPOR_CONFIG_H */
