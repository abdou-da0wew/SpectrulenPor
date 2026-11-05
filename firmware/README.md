# SpectruLenPor ESP32-CAM Smart Glasses Firmware

<img src="https://cdn.jsdelivr.net/npm/@phosphor-icons/core@2.1.1/assets/regular/eye.svg" width="15" align="absMiddle" alt="glasses icon"> Firmware file: [`esp32cam_glasses_firmware.ino`](esp32cam_glasses_firmware.ino)

## Official hardware (locked decision)

The glasses use the **AI-Thinker ESP32-CAM (ESP32-S + WiFi/BT + OV2640 2 MP)** flashed through the **ESP32-CAM-MB** micro-USB programmer shield — no FTDI wiring needed:

| Part | Role | Procurement |
|---|---|---|
| ESP32-CAM (ESP32-S, OV2640) | camera + BLE capture end, UV/IR ADC inputs, flash LED | [Maker Selectronics — ESP32-CAM](https://makerselectronics.com/product/esp32-cam-esp32-s-wifibluetooth-with-ov2640-camera-module/) |
| ESP32-CAM-MB (micro-USB shield, CH340 USB-UART) | one-plug flashing + 5 V power + serial monitor | [Maker Selectronics — ESP32-CAM-MB](https://makerselectronics.com/product/esp32-cam-mb-micro-module-esp32-cam/) |

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

### With the ESP32-CAM-MB shield (recommended — one plug)

1. Install **Arduino IDE 2.x** and add the Espressif **esp32** board package.
2. Select board **AI Thinker ESP32-CAM** (`Partition Scheme: Huge APP (3MB No OTA)`).
3. Seat the ESP32-CAM onto the ESP32-CAM-MB header (camera lens over the board edge), connect the micro-USB cable, and click **Upload** — the shield handles `GPIO0` grounding, CH340 USB-UART, and 5 V power.
4. Press the shield's **RST** button after upload. Verify `SpectruLenPor-ESP32` appears in a BLE scan.

### With a bare board and FTDI adapter (fallback)

1. Same IDE/board settings as above.
2. Bridge `GPIO0` to `GND`, connect via FTDI (`5V` power, `3.3V` logic), and click **Upload**.
3. Disconnect `GPIO0` from `GND` and press **RST**. Verify `SpectruLenPor-ESP32` appears in BLE scan.
