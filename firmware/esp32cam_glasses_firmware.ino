/*
 * ============================================================
 *  SpectrulenPor — ESP32-CAM Smart Glasses Firmware v1.0
 * ============================================================
 *  Streams JPEG frames from the OV2640 camera over Bluetooth
 *  Classic (BLE is too slow for >10 KB frames on ESP32-CAM,
 *  so we use BluetoothSerial with SPP — the Android side can
 *  swap to `flutter_bluetooth_serial` for Classic, or keep BLE
 *  with heavy downscaling. Default sketch below uses BLE with
 *  QVGA frames ~6-15 KB, chunked at 512 bytes / notification.)
 *
 *  Pipeline:
 *    OV2640 (QVGA JPEG) -> ps_frame buffer -> BLE notify chunks
 *
 *  Pairing service contract (must match bluetooth_camera_service.dart):
 *    Service UUID:  0000ffe0-0000-1000-8000-00805f9b34fb
 *    TX char (ffe1): notify — glasses -> phone (JPEG chunks)
 *    RX char (ffe2): write  — phone -> glasses commands
 *      0x01 = start continuous stream (~1 fps)
 *      0x00 = stop stream
 *      0x02 = capture + send exactly one frame
 *
 *  Board: AI-Thinker ESP32-CAM (no USB — use FTDI adapter)
 *  Library deps (Arduino IDE Library Manager):
 *    - "ESP32Servo" not needed here
 *    - esp32 core includes BLE (install "esp32 by Espressif" boards pkg)
 * ============================================================
 */

#include <WiFi.h>          // unused but silences some boards' warnings
#include "esp_camera.h"
#include "BLE2902.h"
#include "BLEDevice.h"

// ---------- OV2640 pin map (AI-Thinker ESP32-CAM) ----------
#define PWDN_GPIO_NUM     32
#define RESET_GPIO_NUM    -1
#define XCLK_GPIO_NUM      0
#define SIOD_GPIO_NUM     26
#define SIOC_GPIO_NUM     27
#define Y9_GPIO_NUM       35
#define Y8_GPIO_NUM       34
#define Y7_GPIO_NUM       39
#define Y6_GPIO_NUM       36
#define Y5_GPIO_NUM       21
#define Y4_GPIO_NUM       19
#define Y3_GPIO_NUM       18
#define Y2_GPIO_NUM        5
#define VSYNC_GPIO_NUM    25
#define HREF_GPIO_NUM     23
#define PCLK_GPIO_NUM     22

// ---------- BLE UUIDs (match the Flutter app) ----------
#define SERVICE_UUID "0000ffe0-0000-1000-8000-00805f9b34fb"
#define TX_CHAR_UUID "0000ffe1-0000-1000-8000-00805f9b34fb"
#define RX_CHAR_UUID "0000ffe2-0000-1000-8000-00805f9b34fb"

// ---------- Stream config ----------
const uint32_t  STREAM_INTERVAL_MS = 1000;  // ~1 fps target
const size_t    CHUNK_SIZE         = 500;   // <= MTU-3; 517 MTU negotiated
const char*     DEVICE_NAME        = "SpectraGlass-ESP32";

BLEServer*         pServer   = nullptr;
BLECharacteristic* pTxChar   = nullptr;
BLECharacteristic* pRxChar   = nullptr;
volatile bool      clientConnected    = false;
volatile bool      streaming          = false;
uint32_t           lastFrameMs        = 0;

// Forward declaration (used by RxCallbacks below)
void sendOneFrame();

// ------------------- camera init -------------------
bool initCamera() {
  camera_config_t cfg;
  cfg.ledc_channel = LEDC_CHANNEL_0;
  cfg.ledc_timer   = LEDC_TIMER_0;
  cfg.pin_d0 = Y2_GPIO_NUM;  cfg.pin_d1 = Y3_GPIO_NUM;
  cfg.pin_d2 = Y4_GPIO_NUM;  cfg.pin_d3 = Y5_GPIO_NUM;
  cfg.pin_d4 = Y6_GPIO_NUM;  cfg.pin_d5 = Y7_GPIO_NUM;
  cfg.pin_d6 = Y8_GPIO_NUM;  cfg.pin_d7 = Y9_GPIO_NUM;
  cfg.pin_xclk = XCLK_GPIO_NUM;
  cfg.pin_pclk = PCLK_GPIO_NUM;
  cfg.pin_vsync = VSYNC_GPIO_NUM;
  cfg.pin_href = HREF_GPIO_NUM;
  cfg.pin_sccb_sda = SIOD_GPIO_NUM;
  cfg.pin_sccb_scl = SIOC_GPIO_NUM;
  cfg.pin_pwdn = PWDN_GPIO_NUM;
  cfg.pin_reset = RESET_GPIO_NUM;
  cfg.xclk_freq_hz = 20000000;
  cfg.pixel_format = PIXFORMAT_JPEG;

  // PSRAM present on AI-Thinker -> QVGA keeps frames ~6-15 KB (BLE-friendly)
  cfg.frame_size   = FRAMESIZE_QVGA;   // 320x240
  cfg.jpeg_quality = 14;               // 10-63; lower = better, bigger
  cfg.fb_count     = 2;
  cfg.fb_location  = CAMERA_FB_IN_PSRAM;
  cfg.grab_mode    = CAMERA_GRAB_LATEST;

  return esp_camera_init(&cfg) == ESP_OK;
}

// ------------------- BLE callbacks -------------------
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override {
    clientConnected = true;
    Serial.println("[BLE] client connected");
  }
  void onDisconnect(BLEServer* s) override {
    clientConnected = false;
    streaming = false;
    BLEDevice::startAdvertising();
    Serial.println("[BLE] client disconnected — advertising again");
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    if (c->getLength() == 0) return;
    uint8_t cmd = c->getData()[0];
    switch (cmd) {
      case 0x01: streaming = true;  Serial.println("[CMD] stream ON");  break;
      case 0x00: streaming = false; Serial.println("[CMD] stream OFF"); break;
      case 0x02: sendOneFrame();    Serial.println("[CMD] single frame"); break;
      default: break;
    }
  }
};

// ------------------- frame capture + send -------------------
void sendOneFrame() {
  if (!clientConnected) return;

  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) { Serial.println("[CAM] capture failed"); return; }

  // Validate JPEG SOI / EOI markers just in case
  bool valid = fb->len > 4 &&
               fb->buf[0] == 0xFF && fb->buf[1] == 0xD8 &&
               fb->buf[fb->len - 2] == 0xFF && fb->buf[fb->len - 1] == 0xD9;

  if (valid) {
    for (size_t off = 0; off < fb->len; off += CHUNK_SIZE) {
      size_t n = (off + CHUNK_SIZE <= fb->len) ? CHUNK_SIZE : (fb->len - off);
      pTxChar->setValue((uint8_t*)(fb->buf + off), n);
      pTxChar->notify();
      // Throttle slightly so the BLE stack doesn't drop notifications
      delay(3);
    }
    Serial.printf("[CAM] sent %u bytes\n", fb->len);
  }

  esp_camera_fb_return(fb);
}

void setup() {
  Serial.begin(115200);
  pinMode(4, OUTPUT);            // onboard flash LED — keep off
  digitalWrite(4, LOW);

  if (!initCamera()) {
    Serial.println("[CAM] init FAILED — halting");
    while (true) delay(1000);
  }
  Serial.println("[CAM] OV2640 ready (QVGA JPEG)");

  BLEDevice::init(DEVICE_NAME);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* svc = server->createService(SERVICE_UUID);

  pTxChar = svc->createCharacteristic(
      TX_CHAR_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  pTxChar->addDescriptor(new BLE2902());   // enable client notifications

  pRxChar = svc->createCharacteristic(
      RX_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
  pRxChar->setCallbacks(new RxCallbacks());  // defined below

  svc->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("[BLE] advertising as SpectraGlass-ESP32");
}

void loop() {
  if (clientConnected && streaming && millis() - lastFrameMs >= STREAM_INTERVAL_MS) {
    lastFrameMs = millis();
    sendOneFrame();
  }
  delay(10);
}
