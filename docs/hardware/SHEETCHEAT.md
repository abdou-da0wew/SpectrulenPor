# SpectruLenPor — Connection & Board Sheetcheats

## Board 1: AI-Thinker ESP32-CAM (Main Board)

**Purpose:** Camera capture, BLE telemetry/commands, WiFi + UDP video, flash LED control  
**MCU:** ESP32-S (single core, 240 MHz)  
**Camera:** OV2640 (2 MP, hardware JPEG encode)  
**PSRAM:** 4 MB  
**Flash:** 4 MB  
**Power:** 5V input → onboard AMS1117 → 3.3V logic

### Pin Allocation Summary

| GPIO | Function | Direction | Notes |
|------|----------|-----------|-------|
| GPIO0 | CAM_XCLK + Boot | Output | Strapping: HIGH=floating=boot, LOW=flash |
| GPIO1 | UART_TX | Output | To programmer |
| GPIO2 | Free | — | Strapping: LOW/floating=boot |
| GPIO3 | UART_RX | Input | From programmer |
| GPIO4 | FLASH_LED | Output | Onboard white LED |
| GPIO5 | CAM_Y2 | Input | Camera data |
| GPIO12 | UV_SENSOR (was) | Input | **MOVED TO GPIO14 — MTDI strapping hazard** |
| GPIO13 | AS7265x_SDA | I2C | Bus 1 data |
| GPIO14 | AS7265x_SCL | I2C | Bus 1 clock (also SD_CLK) |
| GPIO15 | Free | — | Also SD_CMD |
| GPIO16 | PSRAM_CS | — | Do not use |
| GPIO17 | PSRAM | — | Do not use |
| GPIO18 | CAM_Y3 | Input | Camera data |
| GPIO19 | CAM_Y4 | Input | Camera data |
| GPIO21 | CAM_Y5 | Input | Camera data |
| GPIO22 | CAM_PCLK | Input | Pixel clock |
| GPIO23 | CAM_HREF | Input | Horizontal ref |
| GPIO25 | CAM_VSYNC | Input | Vertical sync |
| GPIO26 | CAM_SIOD | I2C | Camera SCCB data (Bus 0) |
| GPIO27 | CAM_SIOC | I2C | Camera SCCB clock (Bus 0) |
| GPIO32 | CAM_PWDN | Output | Camera power-down |
| GPIO33 | Onboard Red LED | Output | Inverted logic |
| GPIO34 | CAM_Y6 | Input | Camera data (input-only) |
| GPIO35 | CAM_Y7 | Input | Camera data (input-only) |
| GPIO36 | CAM_Y8 | Input | Camera data (input-only) |
| GPIO39 | CAM_Y9 | Input | Camera data (input-only) |

---

## Board 2: ESP32-CAM-MB (CH340 Programmer Shield)

**Purpose:** USB programming, bench power, serial monitor  
**Chip:** CH340G USB-to-UART  
**Buttons:** BOOT (GPIO0), RST (EN)  
**Connector:** Micro-USB or USB-C  
**Power:** USB 5V → ESP32-CAM 5V pin

### Wiring (when not using shield as plug-on)

| ESP32-CAM-MB | ESP32-CAM | Function |
|-------------|-----------|----------|
| 5V | 5V | Power |
| GND | GND | Ground |
| TXD | GPIO3 (U0R) | CH340 TX → ESP32 RX |
| RXD | GPIO1 (U0T) | CH340 RX ← ESP32 TX |
| BOOT | GPIO0 | Ground for flash mode |
| RST | EN/CHIP_PU | Reset |

---

## Board 3: AS7265x Spectral Triad

**Purpose:** UV + IR + VIS spectral sensing  
**Chipset:** AS72651 (master) + AS72652 (VIS) + AS72653 (NIR/UV)  
**Interface:** I2C, address 0x49  
**Voltage:** 3.3V only  
**Firmware:** Required on 4Mbit EEPROM (load via UART before first use)

### Channels
| Sensor | Channels | Range |
|--------|----------|-------|
| AS72651 | 6 | VIS (410–535 nm) |
| AS72652 | 6 | VIS/NIR (560–940 nm) |
| AS72653 | 6 | UV/VIS (410–535 nm) |

### LEDs
| LED | Color | Wavelength | Control |
|-----|-------|------------|---------|
| White | Broad | 5700K | Software enable/disable |
| IR | Infrared | 875 nm | Software enable/disable |
| UV | Ultraviolet | 405 nm | Software enable/disable |

---

## Board 4: TP4056 + DW01A Li-ion Charger

**Purpose:** Single-cell Li-ion charging + battery protection  
**Input:** 5V USB (VBUS)  
**Output:** 3.0–4.2V battery voltage  
**Charge Current:** ~1A default (adjustable via Rprog)  
**Protection:** Over-charge, over-discharge, over-current

### Connections

| Pad | Connect To |
|-----|-----------|
| IN+ | USB 5V |
| IN- | USB GND |
| B+ | 18650 Battery + |
| B- | 18650 Battery - |
| OUT+ | Buck-Boost Regulator IN |
| OUT- | Common GND |

---

## Board 5: Buck-Boost Regulator

**Purpose:** Convert variable battery voltage (3.0–4.2V) to stable 5V for ESP32-CAM  
**Input:** 3.0–4.2V from battery  
**Output:** 5V to ESP32-CAM 5V pin  
**Why needed:** ESP32-CAM 5V pin expects regulated 5V; battery voltage sags as it discharges

---

## Software-Firmware Mapping

### BLE GATT (NimBLE)

| Characteristic | UUID | Property | Direction | Flutter Equivalent |
|---------------|------|----------|-----------|-------------------|
| Service | ffe0 | — | — | `serviceUuid` |
| TX | ffe1 | Notify | ESP32 → Phone | `txCharUuid` |
| RX | ffe2 | Write | Phone → ESP32 | `rxCharUuid` |

### Command Bytes (RX)

| Byte | Name | Flutter Method | Firmware Handler |
|------|------|---------------|-----------------|
| 0x00 | CMD_STREAM_OFF | `pauseStream()` | `g_streaming = false` |
| 0x01 | CMD_STREAM_ON | `resumeStream()` | `g_streaming = true` |
| 0x02 | CMD_SINGLE_FRAME | `requestOneFrame()` | `g_streaming = true` (one-shot) |
| 0x03 | CMD_FLASH_ON | `setFlashlight(true)` | `flashlight_set(true)` |
| 0x04 | CMD_FLASH_OFF | `setFlashlight(false)` | `flashlight_set(false)` |
| 0x05 | CMD_RESTART | `restartGlasses()` | `g_restart_requested = true` |
| 0x06 | CMD_SHUTDOWN | `shutdownGlasses()` | `g_shutdown_requested = true` |
| 0x07 | CMD_WIFI_CONFIG_PUT | `wifiConfigPut(ssid, pass)` | Parse "SSID\0PASS\0" |
| 0x08 | CMD_WIFI_CONFIG_GET | `wifiConfigGet()` | `g_wifi_config_get = true` |
| 0x09 | CMD_CONNECTION_STATUS | `connectionStatusGet()` | `g_connection_status_get = true` |

### BLE Responses (TX, notify)

| Packet | Format | Flutter Handler |
|--------|--------|-----------------|
| Telemetry | `$UV:1234;IR:567\n` | `sensorStream` → `SpectrumReading` |
| WiFi Config | `$WIFI_CFG:ssid=XXXX` | `statusMessageStream` |
| Status | `$STATUS:bt=1,wifi=...,ip=...` | `statusMessageStream` |
| WiFi State | `$WIFI:connected\|disconnected` | `statusMessageStream` |
| CMD ACK | `$CMD:stream_on\|off\|...` | `statusMessageStream` |

### UDP Video (port 8888)

| Layer | Protocol | Flutter Service |
|-------|----------|-----------------|
| Transport | UDP | `RawDatagramSocket` |
| Application | Custom header + JPEG | `WifiUdpVideoService` |
| Header | 16 bytes LE (seq/total/offset/size) | Parsed in `_processPacket()` |
| Reassembly | Sequence-ordered chunks | `_framePackets` map |

---

## FreeRTOS Task Architecture

| Task | Priority | Stack | Function |
|------|----------|-------|----------|
| `nimble_host` | 5 | 4096 | NimBLE BLE host stack |
| `telemetry` | 6 | 3072 | UV/IR @ 2Hz, WiFi status @ 2s over BLE |
| `main` | 5 | 4096 | Camera capture + UDP video @ ~10fps |

### Main Loop Timing

| Operation | Interval | Source |
|-----------|----------|--------|
| UV/IR telemetry | 500 ms (2 Hz) | `TELEMETRY_INTERVAL_MS` |
| WiFi status | 2000 ms (0.5 Hz) | `STATUS_INTERVAL_MS` |
| UDP video frame | 100 ms (~10 fps) | `STREAM_INTERVAL_MS` |
| BLE chunk delay | 3 ms | `BLE_CHUNK_SIZE` breathing |

---

## Build & Flash (ESP-IDF on hpc2)

```bash
# On hpc2 (SSH as celestial-dev@vds-cel or hpc2)
cd /home/ababado/Documents/Projects/SpectrulenPor/firmware

# Set target
idf.py set-target esp32

# Configure (optional - review pins, PSRAM, BLE, WiFi)
idf.py menuconfig

# Build
idf.py build

# Flash (ONLY when approved)
idf.py -p /dev/ttyUSB0 flash

# Monitor serial output
idf.py -p /dev/ttyUSB0 monitor
```

**sdkconfig highlights:**
- `CONFIG_ESP32_SPIRAM_SUPPORT=y` — 4MB PSRAM for camera frame buffers
- `CONFIG_BT_NIMBLE_ENABLED=y` — BLE peripheral role
- `CONFIG_ESP_WIFI_STA_ENABLE=y` — WiFi station mode
- `CONFIG_MDNS_ENABLED=y` — mDNS service discovery
- `CONFIG_ESP32_DEFAULT_CPU_FREQ_240=y` — 240 MHz CPU

---

## Partition Table (partitions.csv)

| Name | Type | Subtype | Offset | Size | Flags |
|------|------|---------|--------|------|-------|
| nvs | data | nvs | — | 0x4000 | |
| otadata | data | ota | — | 0x2000 | |
| phy_init | data | phy | — | 0x1000 | |
| factory | app | factory | — | 1M | |
| esp_http_server | data | fat | — | 0x40000 | |

---

## Critical Wiring Rules (Do Not Violate)

1. **GPIO12 must be LOW at boot** — MTDI strapping pin. If HIGH, flash voltage switches to 1.8V and ESP32 fails to boot. UV sensor moved to GPIO14 specifically for this.
2. **AS7265x is 3.3V only** — SDA/SCL/VDD must not exceed 3.3V.
3. **Never connect Li-ion directly to ESP32 3.3V** — Charged cell (4.2V) exceeds ESP32 absolute max (3.6V).
4. **GPIO0 is XCLK + boot pin** — Do not connect peripherals that pull GPIO0 HIGH during reset.
5. **Add 470µF cap on 5V rail** — Camera capture + WiFi TX current spikes trigger brownout without bulk capacitance.
6. **I2C Bus 1 for AS7265x** — Bus 0 (GPIO26/27) is occupied by OV2640 camera SCCB.
7. **AS7265x needs firmware** — Ships blank; must load firmware via UART to EEPROM before I2C reads work.

---

*Sheetcheat generated for SpectruLenPor ESP32-CAM Smart Glasses firmware v3.0 (ESP-IDF)*
