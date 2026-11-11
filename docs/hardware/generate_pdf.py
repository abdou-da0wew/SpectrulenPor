#!/usr/bin/env python3
"""
Generate SpectruLenPor Hardware Wiring PDF with visual diagrams.
Uses reportlab to create tables, colored boxes, and ASCII-art wiring diagrams.
"""
from reportlab.lib.pagesizes import A4, landscape
from reportlab.lib.units import mm, inch
from reportlab.lib.colors import HexColor, white, black
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle,
    PageBreak, KeepTogether, HRFlowable, Preformatted
)
from reportlab.platypus.flowables import Flowable

# ---------------------------------------------------------------------------
# Brand colors (Catppuccin Mocha inspired, matching project palette)
# ---------------------------------------------------------------------------
DUSTY_LAVENDER = HexColor("#825376")
DUSTY_MAUVE = HexColor("#A67E98")
DEEP_PLUM_INK = HexColor("#3A2434")
ALABASTER_GREY = HexColor("#E5E3E1")
DUST_GREY = HexColor("#D4D3CD")
SILVER = HexColor("#C2BEC0")
INK_DARK = HexColor("#1a1a1a")
WARNING = HexColor("#d08770")
SUCCESS = HexColor("#a6da95")

# ---------------------------------------------------------------------------
# Styles
# ---------------------------------------------------------------------------
styles = getSampleStyleSheet()

title_style = ParagraphStyle(
    'Title', parent=styles['Title'],
    fontName='Helvetica-Bold', fontSize=24, textColor=DEEP_PLUM_INK,
    alignment=TA_CENTER, spaceAfter=6
)
subtitle_style = ParagraphStyle(
    'Subtitle', parent=styles['Normal'],
    fontName='Helvetica', fontSize=12, textColor=DUSTY_LAVENDER,
    alignment=TA_CENTER, spaceAfter=2
)
h1_style = ParagraphStyle(
    'H1', parent=styles['Heading1'],
    fontName='Helvetica-Bold', fontSize=16, textColor=DUSTY_LAVENDER,
    spaceBefore=14, spaceAfter=6
)
h2_style = ParagraphStyle(
    'H2', parent=styles['Heading2'],
    fontName='Helvetica-Bold', fontSize=12, textColor=DUSTY_MAUVE,
    spaceBefore=10, spaceAfter=4
)
body_style = ParagraphStyle(
    'Body', parent=styles['Normal'],
    fontName='Helvetica', fontSize=9, textColor=INK_DARK,
    leading=12, spaceAfter=4
)
small_style = ParagraphStyle(
    'Small', parent=styles['Normal'],
    fontName='Helvetica', fontSize=8, textColor=INK_DARK,
    leading=10, spaceAfter=3
)
code_style = ParagraphStyle(
    'Code', parent=styles['Normal'],
    fontName='Courier', fontSize=8, textColor=HexColor("#1e1e1e"),
    leading=10, spaceAfter=4
)
critical_style = ParagraphStyle(
    'Critical', parent=styles['Normal'],
    fontName='Helvetica-Bold', fontSize=9, textColor=WARNING,
    leading=12, spaceAfter=4
)

# ---------------------------------------------------------------------------
# Diagram Flowable: ASCII wiring diagram rendered as text
# ---------------------------------------------------------------------------
class Diagram(Flowable):
    """Renders monospace ASCII diagrams."""
    def __init__(self, lines, width=400, height=200, font_size=8):
        super().__init__()
        self.lines = lines
        self.width = width
        self.height = height
        self.font_size = font_size

    def draw(self):
        self.canv.setFont('Courier', self.font_size)
        self.canv.setFillColor(INK_DARK)
        y = self.height - self.font_size - 4
        for line in self.lines:
            self.canv.drawString(4, y, line)
            y -= self.font_size + 2

# ---------------------------------------------------------------------------
# Build document
# ---------------------------------------------------------------------------
doc = SimpleDocTemplate(
    "/home/ababado/Documents/Projects/SpectrulenPor/docs/hardware/SpectruLenPor_Hardware_Wiring.pdf",
    pagesize=A4,
    leftMargin=18*mm, rightMargin=18*mm,
    topMargin=15*mm, bottomMargin=15*mm,
    title="SpectruLenPor — Hardware Wiring & Assembly Guide",
    author="SpectruLenPor Team",
)

story = []

# ===========================================================================
# TITLE PAGE
# ===========================================================================
story.append(Spacer(1, 20*mm))
story.append(Paragraph("SpectruLenPor", title_style))
story.append(Paragraph("Smart Scientific Glasses — Hardware Wiring & Assembly Guide", subtitle_style))
story.append(Paragraph("ESP32-CAM + AS7265x Spectral Sensor + TP4056 Battery System", subtitle_style))
story.append(Spacer(1, 8*mm))
story.append(HRFlowable(width="60%", thickness=2, color=DUSTY_LAVENDER))
story.append(Spacer(1, 8*mm))

info_table = Table([
    ["Project", "SpectruLenPor — Smart Scientific Glasses"],
    ["Firmware Version", "v3.0 (ESP-IDF, pure ESP-IDF, not Arduino)"],
    ["Hardware", "AI-Thinker ESP32-CAM + AS7265x + TP4056 + 18650"],
    ["Camera", "OV2640, SVGA (800x600), JPEG quality 10"],
    ["Sensors", "AS7265x UV + IR + VIS (I2C bus 1)"],
    ["Video Transport", "WiFi + UDP port 8888 (SVGA JPEG)"],
    ["Control Transport", "BLE NimBLE GATT ffe0/ffe1/ffe2"],
    ["Power", "5V USB → TP4056 → 18650 → Buck-Boost → ESP32-CAM 5V"],
], colWidths=[45*mm, 120*mm])
info_table.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,-1), ALABASTER_GREY),
    ('TEXTCOLOR', (0,0), (-1,-1), DEEP_PLUM_INK),
    ('FONTNAME', (0,0), (0,-1), 'Helvetica-Bold'),
    ('FONTNAME', (1,0), (1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 9),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ('PADDING', (0,0), (-1,-1), 6),
]))
story.append(info_table)
story.append(Spacer(1, 10*mm))
story.append(Paragraph(
    "This document contains complete wiring diagrams, pin assignments, "
    "power chain specifications, assembly instructions, and troubleshooting "
    "for the SpectruLenPor smart glasses hardware system.", body_style
))
story.append(PageBreak())

# ===========================================================================
# MODULE OVERVIEW
# ===========================================================================
story.append(Paragraph("1. Module Overview", h1_style))
story.append(Spacer(1, 3*mm))

module_data = [
    ["Module", "Role", "Interface", "Voltage", "Critical Notes"],
    ["ESP32-CAM", "Main MCU + OV2640 camera + BLE + WiFi", "FPC camera, GPIO headers", "5V in → 3.3V logic", "GPIO12 MUST stay LOW at boot"],
    ["ESP32-CAM-MB", "USB programming & bench power", "Plugs onto ESP32-CAM pins", "5V USB", "Remove after flashing"],
    ["AS7265x", "UV + IR + VIS spectral sensing", "I2C bus 1 (GPIO13/14)", "3.3V only", "Requires firmware on EEPROM"],
    ["TP4056 + DW01A", "Li-ion charging + protection", "USB-C/Micro-USB in", "5V in / 3.0–4.2V out", "Single cell only"],
    ["18650 Li-ion", "Main energy storage", "TP4056 B+/B-", "3.0V–4.2V", "Use protected cell"],
    ["Buck-Boost", "Stable ESP32 supply", "Battery → ESP32-CAM 5V", "3.0–4.2V in → 5V out", "Prevents brownout"],
    ["Flash LED", "Sample illumination", "GPIO4", "3.3V drive", "Active HIGH"],
]
mt = Table(module_data, colWidths=[28*mm, 42*mm, 38*mm, 32*mm, 40*mm], repeatRows=1)
mt.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), DEEP_PLUM_INK),
    ('TEXTCOLOR', (0,0), (-1,0), white),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTNAME', (0,1), (-1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 7.5),
    ('ROWBACKGROUNDS', (0,1), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'TOP'),
    ('PADDING', (0,0), (-1,-1), 4),
]))
story.append(mt)
story.append(PageBreak())

# ===========================================================================
# ESP32-CAM PIN MAP
# ===========================================================================
story.append(Paragraph("2. ESP32-CAM Pin Map (AI-Thinker)", h1_style))
story.append(Spacer(1, 3*mm))
story.append(Paragraph(
    "The OV2640 camera connects via a fixed 24-pin FPC ribbon. These pins are "
    "<b>not available</b> for user wiring:", body_style
))

cam_data = [
    ["Camera Signal", "ESP32 GPIO", "Direction", "Notes"],
    ["PWDN", "GPIO32", "Output", "Camera power-down (active HIGH)"],
    ["RESET", "NC", "—", "Not connected (internal POR)"],
    ["XCLK", "GPIO0", "Output", "Also boot strapping — must NOT be HIGH at boot"],
    ["SIOD (SDA)", "GPIO26", "I2C", "Camera SCCB data (Bus 0)"],
    ["SIOC (SCL)", "GPIO27", "I2C", "Camera SCCB clock (Bus 0)"],
    ["Y2 (D0)", "GPIO5", "Input", "Camera data bit 0"],
    ["Y3 (D1)", "GPIO18", "Input", "Camera data bit 1"],
    ["Y4 (D2)", "GPIO19", "Input", "Camera data bit 2"],
    ["Y5 (D3)", "GPIO21", "Input", "Camera data bit 3"],
    ["Y6 (D4)", "GPIO36", "Input", "Camera data bit 4 (input-only)"],
    ["Y7 (D5)", "GPIO39", "Input", "Camera data bit 5 (input-only)"],
    ["Y8 (D6)", "GPIO34", "Input", "Camera data bit 6 (input-only)"],
    ["Y9 (D7)", "GPIO35", "Input", "Camera data bit 7 (input-only)"],
    ["VSYNC", "GPIO25", "Input", "Vertical sync"],
    ["HREF", "GPIO23", "Input", "Horizontal reference"],
    ["PCLK", "GPIO22", "Input", "Pixel clock"],
]
ct = Table(cam_data, colWidths=[30*mm, 25*mm, 22*mm, 93*mm], repeatRows=1)
ct.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), DEEP_PLUM_INK),
    ('TEXTCOLOR', (0,0), (-1,0), white),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTNAME', (0,1), (-1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 7.5),
    ('ROWBACKGROUNDS', (0,1), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ('PADDING', (0,0), (-1,-1), 3),
]))
story.append(ct)
story.append(Spacer(1, 4*mm))

story.append(Paragraph("Genuinely Free GPIOs", h2_style))
free_data = [
    ["GPIO", "Function", "Direction", "Notes"],
    ["GPIO0", "CAM_XCLK + Boot", "Output", "Strapping: HIGH/floating=boot, LOW=flash"],
    ["GPIO1", "UART_TX", "Output", "To programmer/USB-TTL"],
    ["GPIO2", "Free", "—", "Strapping: LOW/floating at boot"],
    ["GPIO3", "UART_RX", "Input", "From programmer/USB-TTL"],
    ["GPIO4", "FLASH_LED", "Output", "Onboard white flash LED"],
    ["GPIO13", "AS7265x_SDA", "I2C", "Bus 1 data — UV/IR sensor"],
    ["GPIO14", "AS7265x_SCL", "I2C", "Bus 1 clock — UV/IR sensor"],
    ["GPIO15", "Free", "—", "Also SD card CMD"],
    ["GPIO33", "Onboard Red LED", "Output", "Inverted logic (LOW = on)"],
]
ft = Table(free_data, colWidths=[18*mm, 30*mm, 22*mm, 100*mm], repeatRows=1)
ft.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), DUSTY_LAVENDER),
    ('TEXTCOLOR', (0,0), (-1,0), white),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTNAME', (0,1), (-1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 7.5),
    ('ROWBACKGROUNDS', (0,1), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ('PADDING', (0,0), (-1,-1), 3),
]))
story.append(ft)
story.append(Spacer(1, 5*mm))

story.append(Paragraph("Critical Strapping Rules", critical_style))
story.append(Preformatted(
    "GPIO0 : HIGH or floating at boot  →  LOW enters flashing mode\n"
    "GPIO2 : LOW or floating at boot   →  HIGH prevents download mode\n"
    "GPIO12: LOW at boot               →  CRITICAL: if HIGH, flash voltage\n"
    "                                →  switches to 1.8V and ESP32 fails to boot\n",
    code_style
))
story.append(Paragraph(
    "The UV sensor was moved OFF GPIO12 to GPIO14 specifically because GPIO12 "
    "is the MTDI strapping pin. A resistor divider holding GPIO12 HIGH at "
    "power-on will prevent the ESP32 from booting.", body_style
))
story.append(PageBreak())

# ===========================================================================
# AS7265X WIRING
# ===========================================================================
story.append(Paragraph("3. AS7265x Spectral Sensor — I2C Wiring", h1_style))
story.append(Spacer(1, 3*mm))

ascii_diag = Diagram([
    "                    AS7265x Spectral Triad              ESP32-CAM",
    "                    (I2C address 0x49)                  (I2C Bus 1)",
    "                    ┌─────────────┐                    ┌──────────┐",
    "         3.3V ────▶│ VDD         │─────── 3.3V ───────▶│ 3.3V     │",
    "         GND ────▶│ GND         │─────── GND ─────────▶│ GND      │",
    "                    │             │                     │          │",
    "         SDA ─────▶│ TX/SDA (12) │─────── GPIO13 ─────▶│ GPIO13   │",
    "         SCL ─────▶│ RX/SCL (11) │─────── GPIO14 ─────▶│ GPIO14   │",
    "                    │             │                     │          │",
    "         RESN ─────▶│ RESN        │ (internal pull-up)  │          │",
    "         INT  ─────▶│ INT         │ (optional interrupt)│          │",
    "                    └─────────────┘                     └──────────┘",
    "",
    "  Wire colors:  Red=3.3V, Black=GND, White=SDA/SCL",
    "  I2C Bus 1 used because Bus 0 (GPIO26/27) is occupied by OV2640 SCCB.",
    "  CRITICAL: AS7265x is 3.3V only — never connect to 5V rail.",
], width=420, height=230)
story.append(ascii_diag)
story.append(Spacer(1, 5*mm))

story.append(Paragraph("AS7265x Channel Mapping", h2_style))
as7_data = [
    ["Sensor Chip", "Spectral Range", "Channels", "Firmware Role"],
    ["AS72651", "VIS (410–535 nm)", "6", "Master — aggregates all data"],
    ["AS72652", "VIS/NIR (560–940 nm)", "6", "Slave — near-IR"],
    ["AS72653", "UV/VIS (410–535 nm)", "6", "Slave — ultraviolet"],
]
at = Table(as7_data, colWidths=[30*mm, 40*mm, 25*mm, 75*mm], repeatRows=1)
at.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), DUSTY_MAUVE),
    ('TEXTCOLOR', (0,0), (-1,0), white),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTNAME', (0,1), (-1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 7.5),
    ('ROWBACKGROUNDS', (0,1), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('PADDING', (0,0), (-1,-1), 3),
]))
story.append(at)
story.append(Spacer(1, 4*mm))
story.append(Paragraph(
    "Important: AS7265x ships WITHOUT firmware. Firmware must be loaded via "
    "UART to the 4Mbit EEPROM before I2C reads will work. Without firmware, "
    "sensors_init() will return ESP_FAIL and the probe will not detect the chip.",
    body_style
))
story.append(PageBreak())

# ===========================================================================
# POWER CHAIN
# ===========================================================================
story.append(Paragraph("4. Power Chain — TP4056 + Battery + Regulator", h1_style))
story.append(Spacer(1, 3*mm))

power_diag = Diagram([
    "                           POWER CHAIN DIAGRAM",
    "                           ════════════════════",
    "",
    "   USB 5V  ┌─────────────────────────────────────┐",
    "   ───────▶│ TP4056 + DW01A Li-ion Charger       │",
    "           │  IN+/IN-      B+/B-      OUT+/OUT-  │",
    "           └──────────┬──────────┴──────────────┘",
    "                      │        │         │",
    "                      │        │         └──▶ Buck-Boost ──▶ 5V ──▶ ESP32-CAM 5V pin",
    "                      │        │                         │ AMS1117 ──▶ 3.3V ──▶ ESP32 core",
    "                      │        │                         │                    │ GPIO4 ──▶ Flash LED",
    "                      │        └───────────────────────┴──────────────▶ Common GND",
    "                      │",
    "                      └──▶ 18650 Li-ion (3.0–4.2V) ──┘",
    "",
    "   CHRG LED = charging    STDBY LED = charged/floating",
    "",
    "   CRITICAL: Never connect Li-ion (4.2V max) directly to ESP32 3.3V pin.",
    "   Always route through regulator. Add 470µF cap across 5V/GND.",
], width=440, height=260)
story.append(power_diag)
story.append(Spacer(1, 5*mm))

tp_data = [
    ["TP4056 Pad", "Connect To", "Notes"],
    ["IN+", "USB 5V (VBUS)", "Charging input"],
    ["IN-", "USB GND", "Charging ground"],
    ["B+", "Battery + (18650)", "Single cell only"],
    ["B-", "Battery - (18650)", ""],
    ["OUT+", "Buck-Boost IN", "Load output (protected modules)"],
    ["OUT-", "GND common", ""],
]
tt = Table(tp_data, colWidths=[25*mm, 55*mm, 90*mm], repeatRows=1)
tt.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), DEEP_PLUM_INK),
    ('TEXTCOLOR', (0,0), (-1,0), white),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTNAME', (0,1), (-1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 7.5),
    ('ROWBACKGROUNDS', (0,1), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ('PADDING', (0,0), (-1,-1), 3),
]))
story.append(tt)
story.append(Spacer(1, 4*mm))

story.append(Paragraph("Power Budget", h2_style))
power_budget = [
    ["Subsystem", "Peak Current", "Notes"],
    ["OV2640 camera (JPEG capture)", "~160 mA", "During frame capture"],
    ["ESP32 WiFi TX", "~240 mA", "During radio transmission"],
    ["ESP32 BLE TX", "~100 mA", "During BLE advertising/notify"],
    ["ESP32 core (240 MHz)", "~80 mA", "Active processing"],
    ["AS7265x sensor", "~15 mA", "During measurement"],
    ["Flash LED (GPIO4)", "~20 mA", "With current-limiting resistor"],
    ["Total peak (camera + WiFi)", "~400+ mA", "Requires 470µF bulk cap"],
]
pb = Table(power_budget, colWidths=[60*mm, 30*mm, 80*mm], repeatRows=1)
pb.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), DUSTY_LAVENDER),
    ('TEXTCOLOR', (0,0), (-1,0), white),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTNAME', (0,1), (-1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 7.5),
    ('ROWBACKGROUNDS', (0,1), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ('PADDING', (0,0), (-1,-1), 3),
]))
story.append(pb)
story.append(PageBreak())

# ===========================================================================
# DUAL CONNECTION
# ===========================================================================
story.append(Paragraph("5. Dual-Connection Architecture", h1_style))
story.append(Spacer(1, 3*mm))

conn_diag = Diagram([
    "                    DUAL-CONNECTION ARCHITECTURE",
    "                    ══════════════════════════════",
    "",
    "   ┌──────────────┐                                          ┌──────────────┐",
    "   │   PHONE APP  │                                          │   ESP32-CAM  │",
    "   │  (Flutter)   │                                          │   Firmware   │",
    "   └──────┬───────┘                                          └──────┬───────┘",
    "          │                                                          │",
    "          │  BLE: ffe0/ffe1/ffe2                                     │",
    "          │  TX (notify) ◄───────────────────────────────────────────┤",
    "          │       $UV:..;IR:..  $WIFI_CFG:..  $STATUS:..             │",
    "          │                                                          │",
    "          │  RX (write) ───────────────────────────────────────────▶ │",
    "          │       0x00–0x09 (stream, flash, restart, wifi config)   │",
    "          │                                                          │",
    "          │  WiFi + UDP (port 8888)                                  │",
    "          │  ◄───────────────── SVGA JPEG video ───────────────────┤",
    "          │       [seq][total][offset][size][payload] × ~10 fps      │",
    "          │                                                          │",
    "          │  mDNS: spectrulenpor-esp32.local                         │",
    "          │                                                          │",
    "   └──────┴───────┘                                          └──────┴───────┘",
    "",
    "  FLOW: BLE advertise → pair → send WiFi creds over BLE → ESP connects WiFi",
    "  → mDNS broadcast → app finds ESP on LAN → UDP SVGA video starts",
    "  → BLE stays alive for telemetry/commands/warnings",
], width=460, height=300)
story.append(conn_diag)
story.append(Spacer(1, 5*mm))

ble_cmd_data = [
    ["Byte", "Command", "Flutter Method", "Firmware Action"],
    ["0x00", "Stream Off", "pauseStream()", "g_streaming = false"],
    ["0x01", "Stream On", "resumeStream()", "g_streaming = true"],
    ["0x02", "Single Frame", "requestOneFrame()", "g_streaming = true (one frame)"],
    ["0x03", "Flash On", "setFlashlight(true)", "GPIO4 HIGH"],
    ["0x04", "Flash Off", "setFlashlight(false)", "GPIO4 LOW"],
    ["0x05", "Restart", "restartGlasses()", "g_restart_requested = true"],
    ["0x06", "Shutdown", "shutdownGlasses()", "g_shutdown_requested = true"],
    ["0x07", "WiFi Config PUT", "wifiConfigPut(ssid, pass)", "Parse 'SSID\\0PASS\\0'"],
    ["0x08", "WiFi Config GET", "wifiConfigGet()", "g_wifi_config_get = true"],
    ["0x09", "Connection Status", "connectionStatusGet()", "g_connection_status_get = true"],
]
bct = Table(ble_cmd_data, colWidths=[15*mm, 25*mm, 38*mm, 52*mm], repeatRows=1)
bct.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), DUSTY_LAVENDER),
    ('TEXTCOLOR', (0,0), (-1,0), white),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTNAME', (0,1), (-1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 7.5),
    ('ROWBACKGROUNDS', (0,1), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ('PADDING', (0,0), (-1,-1), 3),
]))
story.append(bct)
story.append(Spacer(1, 4*mm))

story.append(Paragraph("UDP Video Packet Format (port 8888)", h2_style))
story.append(Preformatted(
    "Bytes 0-3:   seq    (uint32 LE) — packet sequence within frame\n"
    "Bytes 4-7:   total  (uint32 LE) — total packets in this frame\n"
    "Bytes 8-11:  offset (uint32 LE) — byte offset in JPEG\n"
    "Bytes 12-15: size   (uint32 LE) — payload size\n"
    "Bytes 16+:   JPEG chunk data (max 1384 bytes per packet)\n"
    "\n"
    "Resolution: SVGA 800x600, JPEG quality 10, target ~10 fps\n"
    "Destination: unicast to app IP:port after first contact, broadcast fallback",
    code_style
))
story.append(PageBreak())

# ===========================================================================
# ASSEMBLY CHECKLIST
# ===========================================================================
story.append(Paragraph("6. Assembly Checklist", h1_style))
story.append(Spacer(1, 3*mm))

checklist_data = [
    ["✓", "Step", "Verification"],
    ["□", "ESP32-CAM on work surface", "Board clean, no debris on pins"],
    ["□", "AS7265x wired to GPIO13 (SDA) / GPIO14 (SCL) / 3.3V / GND", "I2C bus 1, 3.3V only"],
    ["□", "Flash LED on GPIO4 with 100–220Ω resistor", "Active HIGH logic"],
    ["□", "18650 battery to TP4056 B+/B-", "Protected cell recommended"],
    ["□", "USB 5V to TP4056 IN+/IN-", "For charging during development"],
    ["□", "TP4056 OUT+/OUT- to buck-boost input", "Stable power path"],
    ["□", "Buck-boost output (5V) to ESP32-CAM 5V pin", "Main system power"],
    ["□", "Common ground across all modules", "Single GND net"],
    ["□", "470µF capacitor across ESP32-CAM 5V/GND", "Prevents brownout"],
    ["□", "GPIO12 NOT pulled HIGH at boot", "UV sensor moved to GPIO14"],
    ["□", "AS7265x firmware loaded to EEPROM", "Required before I2C reads"],
    ["□", "ESP32-CAM-MB removed after flashing", "Development fixture only"],
]
chk = Table(checklist_data, colWidths=[12*mm, 95*mm, 63*mm], repeatRows=1)
chk.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), DUSTY_MAUVE),
    ('TEXTCOLOR', (0,0), (-1,0), white),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTNAME', (0,1), (-1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 8),
    ('ROWBACKGROUNDS', (0,1), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ('PADDING', (0,0), (-1,-1), 4),
]))
story.append(chk)
story.append(PageBreak())

# ===========================================================================
# BOOT SEQUENCE
# ===========================================================================
story.append(Paragraph("7. Boot Sequence", h1_style))
story.append(Spacer(1, 3*mm))

boot_steps = [
    ("1. Power applied", "USB or battery powers TP4056, buck-boost outputs stable 5V/3.3V"),
    ("2. ESP32 bootstrapping", "GPIO0 HIGH/floating, GPIO2 LOW/floating, GPIO12 MUST be LOW"),
    ("3. Firmware app_main()", "flashlight_init() → sensors_init() → camera_init() → ble_init()"),
    ("4. FreeRTOS tasks start", "nimble_host (BLE), telemetry (2 Hz UV/IR), main (~10 fps UDP video)"),
    ("5. BLE advertises", "\"SpectruLenPor-ESP32\" visible to phone app"),
    ("6. Phone pairs via BLE", "Sends WiFi credentials via CMD 0x07 (SSID\\0PASS\\0)"),
    ("7. ESP32 connects WiFi", "mDNS broadcasts spectrulenpor-esp32.local, UDP server starts"),
    ("8. App sends stream-on", "UDP CMD 0x01 → SVGA JPEG video flows at ~10 fps"),
]
bt = Table(
    [[Paragraph(f"<b>{s}</b>", body_style), Paragraph(d, body_style)] for s, d in boot_steps],
    colWidths=[45*mm, 125*mm]
)
bt.setStyle(TableStyle([
    ('ROWBACKGROUNDS', (0,0), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'TOP'),
    ('PADDING', (0,0), (-1,-1), 5),
]))
story.append(bt)
story.append(Spacer(1, 5*mm))

story.append(Paragraph("FreeRTOS Task Architecture", h2_style))
task_data = [
    ["Task", "Priority", "Stack", "Function"],
    ["nimble_host", "5", "4096", "NimBLE BLE host stack"],
    ["telemetry", "6", "3072", "UV/IR @ 2 Hz, WiFi status @ 2 s over BLE"],
    ["main", "5", "4096", "Camera capture + UDP video @ ~10 fps"],
]
tk = Table(task_data, colWidths=[35*mm, 20*mm, 20*mm, 95*mm], repeatRows=1)
tk.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), DEEP_PLUM_INK),
    ('TEXTCOLOR', (0,0), (-1,0), white),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTNAME', (0,1), (-1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 7.5),
    ('ROWBACKGROUNDS', (0,1), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ('PADDING', (0,0), (-1,-1), 3),
]))
story.append(tk)
story.append(PageBreak())

# ===========================================================================
# TROUBLESHOOTING
# ===========================================================================
story.append(Paragraph("8. Troubleshooting", h1_style))
story.append(Spacer(1, 3*mm))

trouble_data = [
    ["Symptom", "Likely Cause", "Fix"],
    ["ESP32 won't boot", "GPIO12 pulled HIGH at boot", "Remove UV sensor from GPIO12; ensure GPIO12 LOW"],
    ["Camera probe failed", "Wrong camera pin map", "Use AI-Thinker pin map (GPIO0 XCLK, GPIO26/27 SCCB)"],
    ["Brownout / random resets", "Insufficient power", "Add 470µF cap; use 5V/1A supply"],
    ["No BLE advertisement", "NimBLE not initialized", "Check ble_init() and host task running"],
    ["No UDP video", "WiFi not connected", "Check credentials sent via BLE CMD 0x07"],
    ["AS7265x not detected", "No firmware / wrong I2C bus", "Load firmware to EEPROM; use I2C1 GPIO13/14"],
    ["Flash LED always on", "GPIO4 stuck HIGH", "Check flashlight_set() state; CMD 0x03/0x04"],
    ["Frame drops / UDP loss", "WiFi interference / buffer full", "Check UDP_MTU_SAFE=1400; reduce frame rate"],
]
td = Table(trouble_data, colWidths=[45*mm, 55*mm, 70*mm], repeatRows=1)
td.setStyle(TableStyle([
    ('BACKGROUND', (0,0), (-1,0), WARNING),
    ('TEXTCOLOR', (0,0), (-1,0), white),
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTNAME', (0,1), (-1,-1), 'Helvetica'),
    ('FONTSIZE', (0,0), (-1,-1), 7.5),
    ('ROWBACKGROUNDS', (0,1), (-1,-1), [white, ALABASTER_GREY]),
    ('GRID', (0,0), (-1,-1), 0.5, DUST_GREY),
    ('VALIGN', (0,0), (-1,-1), 'TOP'),
    ('PADDING', (0,0), (-1,-1), 4),
]))
story.append(td)
story.append(Spacer(1, 5*mm))

story.append(Paragraph("Build & Flash (ESP-IDF on hpc2)", h2_style))
story.append(Preformatted(
    "# On hpc2 via SSH:\n"
    "cd /home/ababado/Documents/Projects/SpectrulenPor/firmware\n"
    "\n"
    "# Set target\n"
    "idf.py set-target esp32\n"
    "\n"
    "# Configure (optional - review pins, PSRAM, BLE, WiFi)\n"
    "idf.py menuconfig\n"
    "\n"
    "# Build\n"
    "idf.py build\n"
    "\n"
    "# Flash (ONLY when approved)\n"
    "idf.py -p /dev/ttyUSB0 flash\n"
    "\n"
    "# Monitor serial output\n"
    "idf.py -p /dev/ttyUSB0 monitor\n",
    code_style
))
story.append(Spacer(1, 4*mm))

story.append(Paragraph("Critical Wiring Rules (Do Not Violate)", critical_style))
rules = [
    "1. GPIO12 must be LOW at boot — MTDI strapping pin. If HIGH, flash voltage switches to 1.8V and ESP32 fails to boot.",
    "2. AS7265x is 3.3V only — SDA/SCL/VDD must not exceed 3.3V.",
    "3. Never connect Li-ion directly to ESP32 3.3V pin — charged cell (4.2V) exceeds ESP32 absolute max (3.6V).",
    "4. GPIO0 is XCLK + boot pin — do not connect peripherals that pull GPIO0 HIGH during reset.",
    "5. Add 470µF cap on 5V rail — camera capture + WiFi TX current spikes trigger brownout without bulk capacitance.",
    "6. I2C Bus 1 for AS7265x — Bus 0 (GPIO26/27) is occupied by OV2640 camera SCCB.",
    "7. AS7265x needs firmware — ships blank; must load firmware via UART to EEPROM before I2C reads work.",
]
for r in rules:
    story.append(Paragraph(r, body_style))

story.append(Spacer(1, 10*mm))
story.append(HRFlowable(width="100%", thickness=1, color=DUST_GREY))
story.append(Spacer(1, 3*mm))
story.append(Paragraph(
    "SpectruLenPor — Smart Scientific Glasses Hardware Wiring & Assembly Guide  |  Firmware v3.0 (ESP-IDF)  |  "
    "Generated from docs/hardware/WIRING_CHEATSHEET.md and docs/hardware/SHEETCHEAT.md",
    small_style
))

doc.build(story)
print("PDF generated successfully at docs/hardware/SpectruLenPor_Hardware_Wiring.pdf")
