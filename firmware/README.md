# SpectruLenPor ESP32-CAM Smart Glasses Firmware

Firmware file: [`esp32cam_glasses_firmware.ino`](esp32cam_glasses_firmware.ino)

## Hardware Pinout (AI-Thinker ESP32-CAM)

| Signal / Sensor | ESP32 GPIO | Notes |
|---|---|---|
| Camera module | Onboard OV2640 | QVGA (`320x240`) JPEG frames |
| UV sensor (GUVA-S12SD analog out) | `GPIO12` | 12-bit ADC (`0–4095`) |
| IR sensor (analog out) | `GPIO13` | 12-bit ADC (`0–4095`) |
| Onboard high-power flash LED | `GPIO4` | Controlled over BLE (`0x03` / `0x04`) |

## BLE GATT Contract (`SpectruLenPor-ESP32`)

| Item | UUID / Byte | Direction | Description |
|---|---|---|---|
| Primary Service | `0000ffe0-0000-1000-8000-00805f9b34fb` | — | Smart-glasses BLE service |
| TX Characteristic | `0000ffe1-0000-1000-8000-00805f9b34fb` | Notify (ESP32 → Phone) | Chunked `FFD8…FFD9` JPEGs + `$UV:<int>;IR:<int>\n` @ 5 Hz |
| RX Characteristic | `0000ffe2-0000-1000-8000-00805f9b34fb` | Write (Phone → ESP32) | Single-byte control commands |
| Pause stream | `0x00` | RX | Stops periodic camera streaming |
| Resume stream | `0x01` | RX | Resumes ~1 fps QVGA JPEG streaming |
| Single frame | `0x02` | RX | Sets `volatile bool singleFrameRequested = true` so `captureAndSendFrame()` runs safely on the main `loop()` task (never inside the NimBLE/BTC callback stack) |
| Flashlight ON | `0x03` | RX | Drives `GPIO4` HIGH |
| Flashlight OFF | `0x04` | RX | Drives `GPIO4` LOW |

## Flashing Instructions

1. Install **Arduino IDE 2.x** and add the Espressif **esp32** board package.
2. Select board **AI Thinker ESP32-CAM** (`Partition Scheme: Huge APP (3MB No OTA)`).
3. Bridge `GPIO0` to `GND`, connect via FTDI (`5V` power, `3.3V` logic), and click **Upload**.
4. Disconnect `GPIO0` from `GND` and press **RST**. Verify `SpectruLenPor-ESP32` appears in BLE scan.
