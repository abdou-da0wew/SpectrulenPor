#ifndef SPECTRULENPOR_CONFIG_H
#define SPECTRULENPOR_CONFIG_H

#include <stdint.h>
#include <stddef.h>

/* ===========================================================================
 *  SpectruLenPor — ESP32-CAM Smart Glasses Firmware v3.0 (ESP-IDF)
 *  Dual connection: BLE (telemetry + commands + WiFi config) + WiFi/UDP
 *  (video streaming).
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
#define PIN_AS7265x_SDA   13   /* I2C bus 1 — not camera SCCB            */
#define PIN_AS7265x_SCL   14   /* GPIO13/14 are safe (not MTDI boot pins)*/

/* ---------------------------------------------------------------------------
 *  OV2640 sensor settings (from camera settings toggle)
 *  Resolution: SVGA (800x600), Quality: 10
 * -------------------------------------------------------------------------- */
#define CAM_FRAME_SIZE    FRAMESIZE_SVGA   /* 800x600                             */
#define CAM_JPEG_QUALITY  10               /* 10 = high quality                   */
#define CAM_BRIGHTNESS    2                /* -2..2 mapped; value here is index   */
#define CAM_CONTRAST      2
#define CAM_SATURATION    2
#define CAM_AEC_LEVEL     2                /* AE level index                      */
#define CAM_AGC_GAINCEIL  2                /* 2x gain ceiling                     */

/* OV2640 register write helper (sensor reg, value) */
#define OV2640_SLV_ADDR   0x30

/* ---------------------------------------------------------------------------
 *  AS7265x spectral sensor (single chip, UV + IR) on I2C1
 * -------------------------------------------------------------------------- */
#define AS7265x_I2C_NUM   I2C_NUM_1
#define AS7265x_I2C_ADDR  0x49
#define AS7265x_I2C_FREQ  100000

/* ---------------------------------------------------------------------------
 *  BLE GATT contract (mirrors lib/services/bluetooth_camera_service.dart)
 * -------------------------------------------------------------------------- */
#define BLE_SVC_UUID      "0000ffe0-0000-1000-8000-00805f9b34fb"
#define BLE_TX_CHAR_UUID  "0000ffe1-0000-1000-8000-00805f9b34fb" /* notify */
#define BLE_RX_CHAR_UUID  "0000ffe2-0000-1000-8000-00805f9b34fb" /* write  */
#define BLE_DEV_NAME      "SpectruLenPor-ESP32"

/* Command bytes (single-byte writes on RX characteristic) */
#define CMD_STREAM_OFF          0x00
#define CMD_STREAM_ON           0x01
#define CMD_SINGLE_FRAME        0x02
#define CMD_FLASH_ON            0x03
#define CMD_FLASH_OFF           0x04
#define CMD_RESTART             0x05
#define CMD_SHUTDOWN            0x06
#define CMD_WIFI_CONFIG_PUT     0x07   /* payload: "SSID\0PASS\0"             */
#define CMD_WIFI_CONFIG_GET     0x08   /* reply: current SSID over TX         */
#define CMD_CONNECTION_STATUS   0x09   /* reply: connection+WiFi status over  */

/* ---------------------------------------------------------------------------
 *  Stream / telemetry timing
 * -------------------------------------------------------------------------- */
#define STREAM_INTERVAL_MS      100   /* UDP video ~10 fps SVGA              */
#define TELEMETRY_INTERVAL_MS   500   /* 2 Hz UV/IR over BLE                 */
#define STATUS_INTERVAL_MS      2000  /* WiFi/battery status over BLE        */
#define BLE_CHUNK_SIZE          500   /* <= MTU-3                            */

/* ---------------------------------------------------------------------------
 *  WiFi / UDP video
 * -------------------------------------------------------------------------- */
#define UDP_VIDEO_PORT          8888
#define UDP_MTU_SAFE            1400   /* safe UDP payload, avoid frag        */
#define UDP_HEADER_LEN          16     /* seq/total/offset/size (4x u32)      */
#define WIFI_HOSTNAME           "spectrulenpor-esp32"
#define WIFI_RETRY_INTERVAL_MS  10000
#define WIFI_MAX_RETRIES        10

/* ---------------------------------------------------------------------------
 *  Shared runtime state (defined in main.c)
 * -------------------------------------------------------------------------- */
extern volatile bool g_client_connected;
extern volatile bool g_streaming;
extern volatile bool g_flash_on;
extern volatile bool g_restart_requested;
extern volatile bool g_shutdown_requested;
extern volatile bool g_wifi_config_get;
extern volatile bool g_connection_status_get;
extern volatile bool g_wifi_config_pending;
extern char          g_wifi_ssid[32];
extern char          g_wifi_pass[64];

/* ---------------------------------------------------------------------------
 *  Packet header for UDP video (16 bytes)
 * -------------------------------------------------------------------------- */
typedef struct __attribute__((packed)) {
    uint32_t seq;        /* packet sequence within this frame   */
    uint32_t total;      /* total packets in this frame         */
    uint32_t offset;     /* byte offset of this chunk in JPEG   */
    uint32_t size;       /* size of this chunk payload          */
} udp_frame_hdr_t;

#endif /* SPECTRULENPOR_CONFIG_H */
