/*
 * ============================================================
 *  SpectruLenPor — ESP32-CAM Smart Glasses Firmware v2.0
 * ============================================================
 *  Per the project paper: the glasses are the CAPTURE end only —
 *  the phone does all processing. This sketch streams:
 *
 *    1. JPEG frames (OV2640, QVGA) over BLE notifications
 *    2. UV + IR sensor telemetry packets between frames
 *       -> "$UV:1234;IR:567\n"   (12-bit ADC raw, 0..4095)
 *    3. Obeys phone commands:
 *       0x01 stream on · 0x00 stream off · 0x02 single frame
 *       0x03 flashlight ON · 0x04 flashlight OFF
 *
 *  Hardware (AI-Thinker ESP32-CAM):
 *    * OV2640 camera (built-in pin map below)
 *    * UV sensor  (GUVA-S12SD or similar, analog out) -> GPIO12 (ADC2)
 *    * IR sensor  (photodiode / thermopile, analog)   -> GPIO13 (ADC2)
 *    * Onboard flash LED (white, bright!)             -> GPIO4
 *
 *  BLE contract (mirrors lib/services/bluetooth_camera_service.dart):
 *    Service ffe0 · TX ffe1 (notify) · RX ffe2 (write)
 * ============================================================
 */

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

// ---------- Sensor + flashlight pins ----------
#define UV_SENSOR_PIN     12   // ADC2 — analog UV sensor out
#define IR_SENSOR_PIN     13   // ADC2 — analog IR sensor out
#define FLASH_LED_PIN      4   // onboard white flash LED

// ---------- BLE UUIDs (match the Flutter app) ----------
#define SERVICE_UUID "0000ffe0-0000-1000-8000-00805f9b34fb"
#define TX_CHAR_UUID "0000ffe1-0000-1000-8000-00805f9b34fb"
#define RX_CHAR_UUID "0000ffe2-0000-1000-8000-00805f9b34fb"

// ---------- Stream config ----------
const uint32_t STREAM_INTERVAL_MS = 1000; // ~1 fps target
const size_t   CHUNK_SIZE         = 500;  // <= MTU-3
const char*    DEVICE_NAME        = "SpectruLenPor-ESP32";

BLEServer*         pServer = nullptr;
BLECharacteristic* pTxChar = nullptr;
BLECharacteristic* pRxChar = nullptr;
volatile bool      clientConnected      = false;
volatile bool      streaming            = false;
volatile bool      singleFrameRequested = false;
volatile bool      flashOn              = false;
uint32_t           lastFrameMs          = 0;
uint32_t           lastTelemetryMs      = 0;

// Forward declaration
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
  cfg.frame_size   = FRAMESIZE_QVGA; // 320x240, BLE-friendly
  cfg.jpeg_quality = 14;
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
    digitalWrite(FLASH_LED_PIN, LOW);
    flashOn = false;
    BLEDevice::startAdvertising();
    Serial.println("[BLE] disconnected — advertising again");
  }
};

class RxCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    if (c->getLength() == 0) return;
    uint8_t cmd = c->getData()[0];
    switch (cmd) {
      case 0x01: streaming = true;  Serial.println("[CMD] stream ON");  break;
      case 0x00: streaming = false; Serial.println("[CMD] stream OFF"); break;
      case 0x02:
        singleFrameRequested = true;
        Serial.println("[CMD] single frame queued");
        break;
      case 0x03:
        flashOn = true;
        digitalWrite(FLASH_LED_PIN, HIGH);   // light the sample
        Serial.println("[CMD] flashlight ON");
        break;
      case 0x04:
        flashOn = false;
        digitalWrite(FLASH_LED_PIN, LOW);
        Serial.println("[CMD] flashlight OFF");
        break;
      default: break;
    }
  }
};

// ------------------- telemetry -------------------
void sendTelemetry() {
  if (!clientConnected || !pTxChar) return;
  uint16_t uv = analogRead(UV_SENSOR_PIN); // 0..4095 (12-bit)
  uint16_t ir = analogRead(IR_SENSOR_PIN);

  char packet[32];
  snprintf(packet, sizeof(packet), "$UV:%u;IR:%u\n", uv, ir);

  pTxChar->setValue((uint8_t*)packet, strlen(packet));
  pTxChar->notify();
}

// ------------------- frame capture + send -------------------
void sendOneFrame() {
  if (!clientConnected) return;

  camera_fb_t* fb = esp_camera_fb_get();
  if (!fb) { Serial.println("[CAM] capture failed"); return; }

  bool valid = fb->len > 4 &&
               fb->buf[0] == 0xFF && fb->buf[1] == 0xD8 &&
               fb->buf[fb->len - 2] == 0xFF && fb->buf[fb->len - 1] == 0xD9;

  if (valid) {
    for (size_t off = 0; off < fb->len; off += CHUNK_SIZE) {
      size_t n = (off + CHUNK_SIZE <= fb->len) ? CHUNK_SIZE : (fb->len - off);
      pTxChar->setValue((uint8_t*)(fb->buf + off), n);
      pTxChar->notify();
      delay(3); // let the BLE stack breathe between chunks
    }
    Serial.printf("[CAM] sent %u bytes\n", fb->len);
  }

  esp_camera_fb_return(fb);
}

void setup() {
  Serial.begin(115200);
  pinMode(FLASH_LED_PIN, OUTPUT);
  digitalWrite(FLASH_LED_PIN, LOW);
  analogReadResolution(12);            // full 0..4095 range
  pinMode(UV_SENSOR_PIN, INPUT);
  pinMode(IR_SENSOR_PIN, INPUT);

  if (!initCamera()) {
    Serial.println("[CAM] init FAILED — halting");
    while (true) delay(1000);
  }
  Serial.println("[CAM] OV2640 ready (QVGA JPEG)");
  Serial.println("[SEN] UV on GPIO12, IR on GPIO13, flash on GPIO4");

  BLEDevice::init(DEVICE_NAME);
  BLEServer* server = BLEDevice::createServer();
  server->setCallbacks(new ServerCallbacks());

  BLEService* svc = server->createService(SERVICE_UUID);

  pTxChar = svc->createCharacteristic(
      TX_CHAR_UUID, BLECharacteristic::PROPERTY_NOTIFY);
  pTxChar->addDescriptor(new BLE2902());

  pRxChar = svc->createCharacteristic(
      RX_CHAR_UUID, BLECharacteristic::PROPERTY_WRITE);
  pRxChar->setCallbacks(new RxCallbacks());

  svc->start();

  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
  Serial.println("[BLE] advertising as SpectruLenPor-ESP32");
}

void loop() {
  uint32_t now = millis();

  // UV/IR telemetry at ~5 Hz (cheap, keeps the spectrum panel live)
  if (clientConnected && now - lastTelemetryMs >= 200) {
    lastTelemetryMs = now;
    sendTelemetry();
  }

  // Single-frame on-demand request (queued from BLE callback on Core 0)
  if (clientConnected && singleFrameRequested) {
    singleFrameRequested = false;
    lastFrameMs = now;
    sendOneFrame();
  }

  // Camera frames at STREAM_INTERVAL_MS
  if (clientConnected && streaming && now - lastFrameMs >= STREAM_INTERVAL_MS) {
    lastFrameMs = now;
    sendOneFrame();
  }

  delay(5);
}
