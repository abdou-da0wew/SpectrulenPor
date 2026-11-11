# SpectruLenPor — Hardware Wiring Cheatsheet

## Overview

| Module | Role | Interface | Voltage |
|--------|------|-----------|---------|
| AI-Thinker ESP32-CAM | Main MCU + OV2640 camera + BLE + WiFi | FPC (camera), GPIO headers | 5V in → 3.3V logic |
| ESP32-CAM-MB (CH340) | USB programming & bench power shield | Plugs onto ESP32-CAM pins | 5V USB |
| AS7265x Spectral Triad | UV + IR + VIS spectral sensing | I2C bus 1 | 3.3V only |
| TP4056 + DW01A | Li-ion charging + battery protection | USB-C/Micro-USB in | 5V in / 3.0–4.2V out |
| 18650 Li-ion cell | Main energy storage | TP4056 B+/B- | 3.0V–4.2V |
| Buck-Boost Regulator | Stable ESP32 supply | Between battery and ESP32-CAM 5V | 3.0–4.2V in → 5V out |
| Onboard Flash LED | Sample illumination | GPIO4 | 3.3V drive |

---

## ESP32-CAM — Fixed Pin Map (AI-Thinker)

The OV2640 camera is connected via 24-pin FPC ribbon. These pins are **not available** for user wiring:

| Camera Signal | ESP32 GPIO | Status |
|--------------|-----------|--------|
| PWDN | GPIO32 | Camera power-down (active HIGH) |
| RESET | NC | Not connected |
| XCLK | GPIO0 | Also boot strapping — must NOT be HIGH at boot |
| SIOD (SDA) | GPIO26 | Camera SCCB I2C data |
| SIOC (SCL) | GPIO27 | Camera SCCB clock |
| Y2 (D0) | GPIO5 | Parallel data bit 0 |
| Y3 (D1) | GPIO18 | Parallel data bit 1 |
| Y4 (D2) | GPIO19 | Parallel data bit 2 |
| Y5 (D3) | GPIO21 | Parallel data bit 3 |
| Y6 (D4) | GPIO36 | Parallel data bit 4 (input-only) |
| Y7 (D5) | GPIO39 | Parallel data bit 5 (input-only) |
| Y8 (D6) | GPIO34 | Parallel data bit 6 (input-only) |
| Y9 (D7) | GPIO35 | Parallel data bit 7 (input-only) |
| VSYNC | GPIO25 | Vertical sync |
| HREF | GPIO23 | Horizontal reference |
| PCLK | GPIO22 | Pixel clock |

### Genuinely Free GPIOs (camera enabled, SD disabled)

| GPIO | Use | Notes |
|------|-----|-------|
| GPIO0 | Restricted | Camera XCLK + boot strapping |
| GPIO1 | UART TX | To programmer/USB-TTL |
| GPIO3 | UART RX | From programmer/USB-TTL |
| GPIO2 | Free | Must be LOW/floating at boot |
| GPIO4 | Flash LED | Onboard white LED |
| GPIO12 | **UV sensor (moved to 14)** | **MTDI strapping — MUST stay LOW at boot** |
| GPIO13 | **AS7265x SDA** | I2C bus 1 data |
| GPIO14 | **AS7265x SCL** | I2C bus 1 clock |
| GPIO15 | Free | Also SD card CMD |
| GPIO16 | PSRAM CS | Do not use |
| GPIO17 | PSRAM | Do not use |
| GPIO33 | Onboard red LED | Inverted logic (LOW = on) |

---

## Strapping Pin Rules (CRITICAL — violations prevent boot)

| Pin | Required State at Boot | Reason |
|-----|----------------------|--------|
| GPIO0 | HIGH or floating | LOW = flashing mode |
| GPIO2 | LOW or floating | HIGH prevents download mode |
| **GPIO12** | **LOW** | **If HIGH → flash voltage switches to 1.8V → ESP32 fails to boot** |

> **UV sensor was moved OFF GPIO12 to GPIO14** specifically because GPIO12 is the MTDI strapping pin. A resistor divider holding GPIO12 HIGH at power-on will brick the boot.

---

## AS7265x — I2C Wiring (I2C Bus 1)

The AS7265x is a 3-chip chipset (AS72651 master + AS72652 VIS + AS72653 NIR/UV) presenting as a single I2C device at **0x49**.

| AS7265x Pin | ESP32 GPIO | Wire Color | Notes |
|------------|-----------|------------|-------|
| VDD | 3.3V | Red | 3.3V only — NOT 5V tolerant |
| GND | GND | Black | Common ground |
| SDA (TX/SDA pin 12) | GPIO13 | White | I2C bus 1 data |
| SCL (RX/SCL pin 11) | GPIO14 | White | I2C bus 1 clock |
| RESN | — | — | Active low reset, internal pull-up |
| INT | — | — | Active low interrupt |

**I2C Bus 1 is used because Bus 0 (GPIO26/27) is occupied by the OV2640 camera SCCB.**

**Important:** AS7265x ships **without firmware**. Firmware must be loaded via UART to the 4Mbit EEPROM before I2C reads will work.

---

## Power Chain — TP4056 + Battery + Regulator

```
USB 5V ──┐
         ├── TP4056 IN+/IN- ──┐
                              ├── B+/B- ── 18650 Li-ion (3.0–4.2V)
                              ├── OUT+/OUT- ── Buck-Boost ── 5V ── ESP32-CAM 5V pin
                              │                              ├── ESP32-CAM AMS1117 ── 3.3V ── ESP32 core
                              │                              └── GPIO4 ── Flash LED
                              └── CHRG/STDBY LEDs ── status indication
```

### TP4056 Wiring

| TP4056 Pad | Connect To | Notes |
|-----------|-----------|-------|
| IN+ | USB 5V (VBUS) | Charging input |
| IN- | USB GND | Charging ground |
| B+ | Battery + (18650) | Single cell only |
| B- | Battery - (18650) | |
| OUT+ | Buck-boost IN | Load output |
| OUT- | GND common | |

### Critical Power Rules
- **Never connect Li-ion directly to ESP32 3.3V pin.** Charged cell = 4.2V, exceeds ESP32 3.6V absolute max.
- Add **470µF capacitor** across 5V/GND near ESP32-CAM for camera + WiFi current spikes.
- Recommended input: **5V / 1A minimum**. Peak draw: camera ~160mA + WiFi/BLE TX ~240mA = **400mA+**.

---

## ESP32-CAM-MB (CH340 Programmer)

Plugs directly onto ESP32-CAM's two 8-pin headers. No user wiring needed for flashing.

| MB Pin | ESP32-CAM Pin | Function |
|--------|--------------|----------|
| 5V | 5V | USB power |
| GND | GND | Common ground |
| TXD | GPIO3 (U0R) | CH340 TX → ESP32 RX |
| RXD | GPIO1 (U0T) | CH340 RX ← ESP32 TX |
| GPIO0 | GPIO0 | BOOT button grounds for flash mode |
| EN | CHIP_PU | RST button pulls low |

**Flashing cycle:**
1. Seat ESP32-CAM on MB shield
2. Connect USB to PC
3. Hold BOOT, press RST, release BOOT → download mode
4. Upload firmware
5. Press RST or power-cycle → runs firmware

> **Remove MB shield before final glasses operation** — it's a development fixture only.

---

## Dual-Connection Architecture

```
                    BLE (NimBLE GATT ffe0/ffe1/ffe2)
              ┌─────────────────────────────────────┐
              │  TX (ffe1, notify) ← ESP32 → Phone  │
              │  RX (ffe2, write)  Phone → ESP32    │
              │  Commands: 0x00–0x09                │
              └─────────────────────────────────────┘
                           │
                           ▼
              WiFi + UDP (port 8888, SVGA JPEG video)
              ┌─────────────────────────────────────┐
              │  UDP packets: [seq][total][offset]  │
              │  [size][payload] — MTU-safe 1400B   │
              │  Unicast after app discovery        │
              └─────────────────────────────────────┘
```

**Flow:** BLE advertise → app pairs → app sends WiFi creds over BLE → ESP connects WiFi + mDNS → app finds ESP on LAN → UDP SVGA video starts; BLE stays alive for telemetry/commands/warnings.

---

## BLE Command Reference (RX characteristic ffe2)

| Byte | Command | Description |
|------|---------|-------------|
| 0x00 | Stream Off | Stop continuous video |
| 0x01 | Stream On | Start continuous video |
| 0x02 | Single Frame | Capture one frame |
| 0x03 | Flash On | GPIO4 HIGH |
| 0x04 | Flash Off | GPIO4 LOW |
| 0x05 | Restart | Reboot ESP32 |
| 0x06 | Shutdown | Stop all activity |
| 0x07 | WiFi Config PUT | Payload: "SSID\0PASS\0" |
| 0x08 | WiFi Config GET | Reply: current SSID over TX |
| 0x09 | Connection Status | Reply: bt/wifi/ip/flash/stream status |

---

## BLE Telemetry / Status (TX characteristic ffe1, notify)

| Packet | Format | Description |
|--------|--------|-------------|
| UV/IR Telemetry | `$UV:1234;IR:567\n` | 2 Hz, 16-bit ADC raw values |
| WiFi Config | `$WIFI_CFG:ssid=XXXX` | Current SSID |
| Connection Status | `$STATUS:bt=1,wifi=connected,ip=192.168.1.50,flash=0,stream=1` | Full status |
| WiFi State | `$WIFI:connected` / `$WIFI:disconnected` | Connection change |
| Command ACK | `$CMD:stream_on` etc. | Command acknowledgment |

---

## UDP Video Packet Format (port 8888)

```
Bytes 0-3:   seq (uint32 LE)   — packet sequence within frame
Bytes 4-7:   total (uint32 LE) — total packets in this frame
Bytes 8-11:  offset (uint32 LE) — byte offset in JPEG
Bytes 12-15: size (uint32 LE)  — payload size
Bytes 16+:   JPEG chunk data   (max 1400 - 16 = 1384 bytes per packet)
```

- Resolution: SVGA 800x600, JPEG quality 10
- Target: ~10 fps
- Destination: unicast to app IP:port after first contact, broadcast fallback

---

## Assembly Checklist

- [ ] ESP32-CAM seated on work surface
- [ ] AS7265x wired to GPIO13 (SDA) / GPIO14 (SCL) / 3.3V / GND
- [ ] Flash LED on GPIO4 with current-limiting resistor (100–220Ω)
- [ ] 18650 battery connected to TP4056 B+/B-
- [ ] USB 5V connected to TP4056 IN+/IN- for charging
- [ ] TP4056 OUT+/OUT- connected to buck-boost regulator input
- [ ] Buck-boost output (5V) connected to ESP32-CAM 5V pin
- [ ] Common ground between all modules
- [ ] 470µF capacitor across ESP32-CAM 5V/GND
- [ ] GPIO12 NOT pulled HIGH by any divider at boot
- [ ] AS7265x firmware loaded to EEPROM before first use
- [ ] ESP32-CAM-MB removed after flashing

---

## Boot Sequence

1. Power applied (USB or battery)
2. TP4056 charges battery if USB present
3. Buck-boost outputs stable 5V/3.3V
4. ESP32 bootstrapping: GPIO0 HIGH/floating, GPIO2 LOW/floating, **GPIO12 LOW**
5. Firmware `app_main()`: flashlight init → sensors init → camera init → BLE init → FreeRTOS tasks start
6. BLE advertises "SpectruLenPor-ESP32"
7. Phone pairs via BLE, sends WiFi creds
8. ESP32 connects WiFi, mDNS broadcasts, UDP video server starts
9. Phone sends stream-on over UDP → SVGA video flows

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| ESP32 won't boot | GPIO12 pulled HIGH | Remove UV sensor from GPIO12, ensure GPIO12 LOW at boot |
| "Camera probe failed" | Wrong pin map | Use AI-Thinker pin map (GPIO0 XCLK, GPIO26/27 SCCB) |
| Brownout / random resets | Insufficient power | Add 470µF cap, use 5V/1A supply |
| No BLE advertisement | NimBLE not initialized | Check `ble_init()` called, NimBLE host task running |
| No UDP video | WiFi not connected | Check credentials sent via BLE CMD 0x07 |
| AS7265x not detected | No firmware / wrong I2C bus | Load firmware to EEPROM, use I2C1 GPIO13/14 |
| Flash LED always on | GPIO4 stuck | Check flashlight_set() state, CMD 0x03/0x04 |

---

## File Structure (firmware/)

```
firmware/
├── CMakeLists.txt          # ESP-IDF project root
├── config.h                # All pins, UUIDs, timing, commands
├── partitions.csv          # Flash partition table
├── sdkconfig               # Build configuration
├── README.md               # Hardware & flashing info
└── components/
    ├── main/main.c         # FreeRTOS orchestration loop
    ├── camera/             # OV2640 SVGA driver
    ├── sensors/            # AS7265x I2C driver
    ├── flashlight/         # GPIO4 LED control
    ├── ble/                # NimBLE GATT server
    ├── wifi/               # WiFi STA + mDNS
    └── udp_stream/         # UDP video tx + rx
```

---

*Document generated for SpectruLenPor ESP32-CAM Smart Glasses firmware v3.0 (ESP-IDF)*
