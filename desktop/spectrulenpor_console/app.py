"""GNOME-native GTK4/Libadwaita application UI."""
from __future__ import annotations

import math
import os
import threading
import time
from collections import deque
from concurrent.futures import ThreadPoolExecutor

import gi
gi.require_version("Gtk", "4.0")
gi.require_version("Adw", "1")
gi.require_version("Gdk", "4.0")
from gi.repository import Adw, Gdk, Gio, GLib, Gtk, Pango

from .bluetooth import BluezClient, BleDevice
from .network import default_wifi_interface, current_ssid, scan_wifi
from .protocol import (
    CMD_FLASH_OFF, CMD_FLASH_ON, CMD_SINGLE_FRAME, CMD_STREAM_OFF,
    CMD_STREAM_ON, CMD_SET_VIDEO_PROFILE, VIDEO_PROFILE_AUTO,
    SPECTRAL_CHANNELS, encode_video_profile, parse_spectrum, parse_status_line,
)
from .serial_monitor import SerialMonitor, parse_uart_metrics, serial_ports
from .udp import UdpStreamClient


CSS = """
.metric-card { border: 1px solid alpha(currentColor, 0.10); border-radius: 14px; background: @card_bg_color; }
.metric-value { font-size: 28px; font-weight: 700; letter-spacing: -0.8px; }
.metric-caption { color: alpha(currentColor, 0.62); font-size: 12px; }
.section-title { font-size: 19px; font-weight: 700; }
.eyebrow { color: alpha(currentColor, 0.60); font-size: 11px; font-weight: 700; letter-spacing: 0.08em; }
.device-row { padding: 8px; }
.video-stage { background: #0b1017; border-radius: 16px; }
.video-placeholder { color: #aab4c0; }
.mono { font-family: monospace; font-size: 12px; }
.nav-button { min-height: 42px; }
.status-dot { min-width: 8px; min-height: 8px; border-radius: 99px; background: #8a8a8a; }
.status-dot.connected { background: #2ec27e; }
.status-dot.warning { background: #e5a50a; }
.sensor-number { font-size: 34px; font-weight: 700; }
.panel-muted { color: alpha(currentColor, 0.60); }
"""


def label(text="", css=None, size=None, wrap=False):
    item = Gtk.Label(label=str(text), xalign=0, yalign=0.5)
    if css: item.add_css_class(css)
    if size: item.set_size_request(size, -1)
    if wrap: item.set_wrap(True)
    return item


def button(text, icon=None, css=None):
    item = Gtk.Button()
    if icon:
        child = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        child.append(Gtk.Image.new_from_icon_name(icon))
        child.append(Gtk.Label(label=text))
        item.set_child(child)
    else:
        item.set_label(text)
    if css: item.add_css_class(css)
    return item


def card_box():
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
    box.set_margin_top(14); box.set_margin_bottom(14)
    box.set_margin_start(16); box.set_margin_end(16)
    frame = Gtk.Frame()
    frame.add_css_class("metric-card")
    frame.set_child(box)
    return frame, box


class SpectruLenPorWindow(Adw.ApplicationWindow):
    def __init__(self, application):
        super().__init__(application=application, title="SpectruLenPor Lab")
        self.set_default_size(1440, 940)
        self.set_size_request(1120, 720)
        self.executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="spectrulenpor")
        self.ble: BluezClient | None = None
        self.udp: UdpStreamClient | None = None
        self._udp_generation = 0
        self.serial: SerialMonitor | None = None
        self.ble_devices: list[BleDevice] = []
        self.selected_ble: BleDevice | None = None
        self.wifi_interface = default_wifi_interface()
        self.wifi_networks = []
        self.current_status = {}
        self.latest_metrics = {}
        self.uart_metrics = {}
        self.log_lines = deque(maxlen=2500)
        self.frame_count = 0
        self._last_frame_log = 0.0
        self.spectrum_values = {}
        self._last_ui_metrics = {}
        self._build_ui()
        self._install_css()
        self._refresh_serial_ports()
        self._refresh_network_header()
        self._log("Console ready. BLE commissioning, UDP video and UART diagnostics are available.")
        self._set_connection_state("Bluetooth not connected", "neutral")
        self.connect("close-request", self._on_close)

    def _install_css(self):
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS.encode())
        Gtk.StyleContext.add_provider_for_display(
            Gdk.Display.get_default(), provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def _build_ui(self):
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        header = Adw.HeaderBar()
        title = Adw.WindowTitle(title="SpectruLenPor Lab", subtitle="ESP32-CAM diagnostics")
        header.set_title_widget(title)
        self.header_status = Gtk.Label(label="Disconnected")
        self.header_status.add_css_class("dim-label")
        header.pack_end(self.header_status)
        root.append(header)

        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=0)
        sidebar = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        sidebar.set_size_request(238, -1)
        sidebar.set_margin_top(16); sidebar.set_margin_start(12); sidebar.set_margin_end(12)
        sidebar.append(label("DEVICE WORKSPACE", "eyebrow"))
        sidebar.append(label("SpectruLenPor", "section-title"))
        sidebar.append(label("ESP32-CAM · OV2640 · AS7265x", "metric-caption"))
        self.sidebar_status = label("●  Not connected")
        sidebar.append(self.sidebar_status)
        sidebar.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        self.nav_buttons = {}
        for key, text, icon in (
            ("overview", "Overview", "view-dashboard-symbolic"),
            ("commissioning", "BLE → Wi-Fi setup", "bluetooth-symbolic"),
            ("stream", "Live video", "camera-video-symbolic"),
            ("sensors", "Spectral sensors", "applications-science-symbolic"),
            ("diagnostics", "Diagnostics & UART", "utilities-terminal-symbolic"),
        ):
            row = Gtk.Button()
            child = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
            child.set_margin_top(5); child.set_margin_bottom(5)
            child.set_margin_start(4); child.set_margin_end(4)
            child.append(Gtk.Image.new_from_icon_name(icon))
            child.append(Gtk.Label(label=text, xalign=0))
            row.set_child(child); row.add_css_class("flat"); row.add_css_class("nav-button")
            row.connect("clicked", self._navigate, key)
            sidebar.append(row)
            self.nav_buttons[key] = row
        sidebar.append(Gtk.Box(vexpand=True))
        sidebar.append(label("TRANSPORT", "eyebrow"))
        self.transport_label = label("BLE  Offline\nUDP  Offline\nUART  Idle")
        self.transport_label.add_css_class("metric-caption")
        sidebar.append(self.transport_label)

        self.stack = Gtk.Stack(transition_type=Gtk.StackTransitionType.CROSSFADE,
                               transition_duration=180, hexpand=True, vexpand=True)
        self.stack.set_margin_start(18); self.stack.set_margin_end(18)
        self.stack.set_margin_top(10); self.stack.set_margin_bottom(12)
        self._build_overview()
        self._build_commissioning()
        self._build_stream()
        self._build_sensors()
        self._build_diagnostics()
        body.append(sidebar)
        body.append(Gtk.Separator(orientation=Gtk.Orientation.VERTICAL))
        body.append(self.stack)
        root.append(body)

        footer = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        footer.set_margin_start(18); footer.set_margin_end(18)
        footer.set_margin_top(6); footer.set_margin_bottom(8)
        self.footer_left = label("Ready", "metric-caption")
        self.footer_right = label("UDP :8888  ·  V2 / JPEG / XOR-FEC", "metric-caption")
        footer.append(self.footer_left)
        footer.append(Gtk.Box(hexpand=True))
        footer.append(self.footer_right)
        root.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        root.append(footer)
        self.set_content(root)
        self._navigate(None, "overview")

    def _page(self, name):
        scroller = Gtk.ScrolledWindow(hexpand=True, vexpand=True)
        scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        content.set_margin_top(12); content.set_margin_bottom(26)
        content.set_margin_start(2); content.set_margin_end(8)
        scroller.set_child(content)
        self.stack.add_named(scroller, name)
        return content

    def _heading(self, parent, title, subtitle):
        block = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=5)
        block.append(label(title, "section-title"))
        block.append(label(subtitle, "metric-caption", wrap=True))
        parent.append(block)

    def _metric(self, parent, key, title, value="—", detail="Waiting for telemetry", position=None):
        frame, box = card_box()
        box.append(label(title.upper(), "eyebrow"))
        value_label = label(value, "metric-value")
        detail_label = label(detail, "metric-caption", wrap=True)
        box.append(value_label); box.append(detail_label)
        frame.set_hexpand(True)
        if isinstance(parent, Gtk.Grid):
            if position is None:
                raise ValueError("Grid metric cards require an explicit position")
            parent.attach(frame, position[0], position[1], 1, 1)
        else:
            parent.append(frame)
        self.metric_widgets[key] = (value_label, detail_label)
        return frame

    def _metric_grid(self, parent, metrics, columns=4):
        self.metric_widgets = getattr(self, "metric_widgets", {})
        grid = Gtk.Grid(column_spacing=12, row_spacing=12, hexpand=True)
        for index, item in enumerate(metrics):
            key, title, value, detail = item
            col, row = index % columns, index // columns
            self._metric(grid, key, title, value, detail, position=(col, row))
        parent.append(grid)

    def _build_overview(self):
        page = self._page("overview")
        self._heading(page, "Device overview", "A live readout of what the ESP32 reports, what the receiver gets, and how the link behaves.")
        self._metric_grid(page, [
            ("fps", "Received FPS", "0.0", "Validated JPEG frames per second"),
            ("rssi", "ESP32 Wi-Fi RSSI", "—", "Reported by the ESP32 station"),
            ("throughput", "Video throughput", "0 KB/s", "Decoded frame payload"),
            ("frame", "Latest frame", "—", "Waiting for the first complete frame"),
            ("heap", "Internal heap", "—", "Free / minimum free"),
            ("psram", "PSRAM", "—", "Camera frame memory"),
            ("packet", "UDP datagrams", "0", "Data + parity + control"),
            ("recovery", "FEC recovery", "0", "Recovered missing JPEG fragments"),
            ("channel", "Wi-Fi channel", "—", "ESP32 station AP channel"),
            ("invalid", "Invalid packets", "0", "Rejected malformed UDP datagrams"),
        ], columns=4)
        panel = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        left_frame, left = card_box()
        left.append(label("DEVICE HEALTH", "eyebrow"))
        self.health_summary = label("Waiting for ESP32 status…", wrap=True)
        left.append(self.health_summary)
        left.append(label("The ESP32 status packet includes Wi-Fi RSSI, the active camera profile, heap, PSRAM, frame/error counters, and AS7265x raw channel readings.", "metric-caption", wrap=True))
        panel.append(left_frame)
        right_frame, right = card_box()
        right.append(label("QUICK ACTIONS", "eyebrow"))
        for text, icon, callback in (
            ("Find device over BLE", "bluetooth-symbolic", lambda *_: self._navigate(None, "commissioning")),
            ("Discover UDP peer", "network-wireless-symbolic", lambda *_: self._start_udp()),
            ("Open live video", "camera-video-symbolic", lambda *_: self._navigate(None, "stream")),
            ("Refresh ESP32 status", "view-refresh-symbolic", lambda *_: self._request_status()),
        ):
            action = button(text, icon, "flat"); action.connect("clicked", callback); right.append(action)
        panel.append(right_frame)
        page.append(panel)
        self.overview_link = label("Laptop Wi-Fi: checking…", "metric-caption")
        page.append(self.overview_link)

    def _build_commissioning(self):
        page = self._page("commissioning")
        self._heading(page, "BLE → Wi-Fi commissioning", "The same sequence used by the mobile app: discover the ESP32, connect to FFE0, pair, provision credentials, reboot, then discover the UDP peer.")
        columns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14, homogeneous=True)
        ble_frame, ble_box = card_box()
        ble_box.append(label("01 · BLUETOOTH LE", "eyebrow"))
        self.ble_state = label("Bluetooth adapter not checked")
        ble_box.append(self.ble_state)
        buttons = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.scan_ble_button = button("Scan for ESP32", "bluetooth-searching-symbolic", "suggested-action")
        self.scan_ble_button.connect("clicked", lambda *_: self._scan_ble())
        buttons.append(self.scan_ble_button)
        self.connect_ble_button = button("Connect", "network-connect-symbolic")
        self.connect_ble_button.connect("clicked", lambda *_: self._connect_ble())
        buttons.append(self.connect_ble_button)
        ble_box.append(buttons)
        self.ble_device_list = Gtk.ListBox(selection_mode=Gtk.SelectionMode.SINGLE)
        self.ble_device_list.add_css_class("boxed-list")
        self.ble_device_list.connect("row-selected", self._ble_selected)
        ble_scroll = Gtk.ScrolledWindow(min_content_height=150, max_content_height=220)
        ble_scroll.set_child(self.ble_device_list)
        ble_box.append(ble_scroll)
        self.pair_code = Gtk.Entry(text="11111", max_length=5, input_purpose=Gtk.InputPurpose.PIN)
        self.pair_code.set_placeholder_text("Pairing code")
        ble_box.append(label("Application pairing code", "metric-caption"))
        ble_box.append(self.pair_code)
        self.pair_button = button("Pair with ESP32", "channel-secure-symbolic")
        self.pair_button.connect("clicked", lambda *_: self._pair_ble())
        ble_box.append(self.pair_button)
        self.ble_identity = label("No device identity received yet.", "metric-caption", wrap=True)
        ble_box.append(self.ble_identity)
        columns.append(ble_frame)

        wifi_frame, wifi_box = card_box()
        wifi_box.append(label("02 · WI-FI PROVISIONING", "eyebrow"))
        wifi_box.append(label("Nearby networks · scanned by this laptop's Wi-Fi adapter", "metric-caption"))
        self.wifi_dropdown = Gtk.DropDown.new_from_strings(["Scan for networks…"])
        self.wifi_dropdown.connect("notify::selected", self._wifi_selection_changed)
        wifi_box.append(self.wifi_dropdown)
        network_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.wifi_scan_button = button("Scan nearby Wi-Fi", "view-refresh-symbolic")
        self.wifi_scan_button.connect("clicked", lambda *_: self._scan_wifi())
        network_row.append(self.wifi_scan_button)
        self.wifi_interface_label = label(self.wifi_interface or "No Wi-Fi interface", "metric-caption")
        network_row.append(self.wifi_interface_label)
        wifi_box.append(network_row)
        self.ssid_entry = Gtk.Entry(placeholder_text="Wi-Fi SSID")
        self.password_entry = Gtk.Entry(visibility=False, placeholder_text="Wi-Fi password")
        wifi_box.append(label("SSID", "metric-caption")); wifi_box.append(self.ssid_entry)
        wifi_box.append(label("Password", "metric-caption")); wifi_box.append(self.password_entry)
        self.provision_button = button("Save credentials & reboot", "network-wireless-symbolic", "suggested-action")
        self.provision_button.connect("clicked", lambda *_: self._provision_wifi())
        wifi_box.append(self.provision_button)
        wifi_box.append(label("The password is sent directly to the paired ESP32 over BLE. The app does not save it. A reboot is required before UDP discovery.", "metric-caption", wrap=True))
        self.udp_discovery_button = button("Find device over UDP", "radar-symbolic")
        self.udp_discovery_button.connect("clicked", lambda *_: self._start_udp())
        wifi_box.append(self.udp_discovery_button)
        self.udp_ip_entry = Gtk.Entry(placeholder_text="Optional ESP32 IP, or leave empty for broadcast")
        wifi_box.append(self.udp_ip_entry)
        columns.append(wifi_frame)
        page.append(columns)

        self.commissioning_status = label("Waiting for Bluetooth scan.", "metric-caption", wrap=True)
        page.append(self.commissioning_status)
        self._set_commission_controls(False, False)

    def _build_stream(self):
        page = self._page("stream")
        self._heading(page, "Live camera stream", "Actual UDP V2 frames from the ESP32. FPS only increments after a full JPEG is reassembled and validated.")
        bar = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.udp_state = label("UDP peer: not connected")
        bar.append(self.udp_state)
        bar.append(Gtk.Box(hexpand=True))
        self.ip_entry_stream = Gtk.Entry(placeholder_text="ESP32 IP (optional)", width_chars=18)
        bar.append(self.ip_entry_stream)
        self.discover_udp_button = button("Discover", "radar-symbolic", "suggested-action")
        self.discover_udp_button.connect("clicked", lambda *_: self._start_udp(self.ip_entry_stream.get_text().strip() or None))
        bar.append(self.discover_udp_button)
        page.append(bar)

        profile_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=10)
        profile_row.set_margin_top(4)
        profile_row.set_margin_bottom(4)
        profile_row.append(label("CAMERA RESOLUTION", "eyebrow"))
        self.video_profile_dropdown = Gtk.DropDown.new_from_strings([
            "Auto · adaptive to Wi-Fi RSSI",
            "XGA · 1024 × 768",
            "SVGA · 800 × 600",
            "VGA · 640 × 480",
            "QVGA · 320 × 240",
            "QQVGA · 160 × 120",
        ])
        self.video_profile_dropdown.set_selected(0)
        self.video_profile_dropdown.set_hexpand(True)
        profile_row.append(self.video_profile_dropdown)
        self.profile_apply_button = button("Apply", "check-symbolic", "suggested-action")
        self.profile_apply_button.connect("clicked", lambda *_: self._apply_video_profile())
        profile_row.append(self.profile_apply_button)
        page.append(profile_row)
        self.profile_result_label = label(
            "Automatic mode lets the ESP32 choose its profile from the measured link RSSI.",
            "metric-caption",
            wrap=True,
        )
        page.append(self.profile_result_label)

        columns = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=14)
        video_frame = Gtk.Frame(hexpand=True, vexpand=True)
        video_frame.add_css_class("video-stage")
        video_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        video_box.set_margin_top(10); video_box.set_margin_bottom(10)
        video_box.set_margin_start(10); video_box.set_margin_end(10)
        self.picture = Gtk.Picture(content_fit=Gtk.ContentFit.CONTAIN, hexpand=True, vexpand=True)
        self.picture.set_size_request(640, 430)
        self.picture.add_css_class("video-stage")
        video_box.append(self.picture)
        self.video_placeholder = label("No frames received yet\nDiscover the UDP peer, then start streaming.", "video-placeholder", wrap=True)
        self.video_placeholder.set_justify(Gtk.Justification.CENTER)
        video_box.append(self.video_placeholder)
        self.video_dimensions = label("— × —  ·  JPEG", "metric-caption")
        video_box.append(self.video_dimensions)
        video_frame.set_child(video_box)
        columns.append(video_frame)

        controls_frame, controls = card_box()
        controls_frame.set_size_request(260, -1)
        controls.append(label("STREAM CONTROLS", "eyebrow"))
        self.stream_button = button("Start stream", "media-playback-start-symbolic", "suggested-action")
        self.stream_button.connect("clicked", lambda *_: self._stream_on())
        controls.append(self.stream_button)
        self.stop_stream_button = button("Stop stream", "media-playback-stop-symbolic")
        self.stop_stream_button.connect("clicked", lambda *_: self._stream_off())
        controls.append(self.stop_stream_button)
        self.single_button = button("Capture one frame", "camera-photo-symbolic")
        self.single_button.connect("clicked", lambda *_: self._send_udp_command(CMD_SINGLE_FRAME))
        controls.append(self.single_button)
        controls.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        controls.append(label("Flashlight", "metric-caption"))
        flash_row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.flash_on_button = button("On", "flashlight-symbolic")
        self.flash_on_button.connect("clicked", lambda *_: self._send_udp_command(CMD_FLASH_ON))
        self.flash_off_button = button("Off", "flashlight-off-symbolic")
        self.flash_off_button.connect("clicked", lambda *_: self._send_udp_command(CMD_FLASH_OFF))
        flash_row.append(self.flash_on_button); flash_row.append(self.flash_off_button)
        controls.append(flash_row)
        controls.append(Gtk.Separator(orientation=Gtk.Orientation.HORIZONTAL))
        self.live_stat_labels = {}
        for key, title in (("fps", "Received FPS"), ("rssi", "ESP32 RSSI"),
                           ("bytes", "Latest JPEG"), ("assembly", "Assembly time"),
                           ("capture", "Camera capture"), ("send", "UDP send"),
                           ("interval", "Next-frame gap"),
                           ("jitter", "Frame interval jitter"), ("recovered", "Recovered fragments")):
            line = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
            line.append(label(title, "metric-caption"))
            value = label("—")
            value.set_xalign(1); value.set_hexpand(True)
            line.append(value); controls.append(line)
            self.live_stat_labels[key] = value
        columns.append(controls_frame)
        page.append(columns)
        self._set_udp_controls(False)

    def _build_sensors(self):
        page = self._page("sensors")
        self._heading(
            page,
            "Spectral sensor telemetry",
            "The AS7265x chipset exposes 18 optical channels from 410–940 nm and three die-temperature readings. Spectrum values are raw ADC counts, not calibrated irradiance.",
        )
        self._metric_grid(page, [
            ("sensor_state", "Sensor availability", "Unknown", "AS72651 + AS72652 + AS72653"),
            ("sensor_valid", "Latest sample", "—", "Waiting for data-ready sample"),
            ("temp_as72653", "AS72653 temperature", "—", "Shortwave die · °C"),
            ("temp_as72652", "AS72652 temperature", "—", "Middle-band die · °C"),
            ("temp_as72651", "AS72651 temperature", "—", "Controller / longwave die · °C"),
        ], columns=5)
        channel_metrics = [
            (f"spectrum_{wavelength}", f"{channel} · {wavelength} nm", "—", f"{device} · raw count")
            for channel, wavelength, device in SPECTRAL_CHANNELS
        ]
        self._metric_grid(page, channel_metrics, columns=6)

        chart_frame = Gtk.Frame()
        chart_frame.add_css_class("metric-card")
        chart = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        chart.set_margin_top(14); chart.set_margin_bottom(14)
        chart.set_margin_start(16); chart.set_margin_end(16)
        chart.append(label("LIVE SPECTRAL RESPONSE", "eyebrow"))
        self.sensor_chart = Gtk.DrawingArea(content_width=900, content_height=300, hexpand=True)
        self.sensor_chart.set_draw_func(self._draw_sensor_chart)
        chart.append(self.sensor_chart)
        self.spectrum_chart_status = label("Waiting for all 18 channels.", "metric-caption")
        chart.append(self.spectrum_chart_status)
        chart_frame.set_child(chart)
        page.append(chart_frame)
        self.sensor_note = label(
            "The ESP32 samples the three AS7265x dies when a status snapshot is requested. Missing or not-ready values remain blank. Raw counts are useful for repeatable comparisons, but they are not calibrated spectral power or lux.",
            "metric-caption",
            wrap=True,
        )
        page.append(self.sensor_note)

    def _build_diagnostics(self):
        page = self._page("diagnostics")
        self._heading(page, "Diagnostics & serial console", "Read the ESP32 UART logs without toggling reset lines. Firmware performance summaries include FPS, fragment counts, retries, retry backoff, and heap.")
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.serial_port_entry = Gtk.Entry(placeholder_text="/dev/ttyUSB0", width_chars=20)
        row.append(self.serial_port_entry)
        self.serial_refresh_button = button("Refresh ports", "view-refresh-symbolic")
        self.serial_refresh_button.connect("clicked", lambda *_: self._refresh_serial_ports())
        row.append(self.serial_refresh_button)
        self.serial_button = button("Start UART monitor", "utilities-terminal-symbolic", "suggested-action")
        self.serial_button.connect("clicked", lambda *_: self._toggle_serial())
        row.append(self.serial_button)
        clear_button = button("Clear log", "edit-clear-symbolic")
        clear_button.connect("clicked", lambda *_: self._clear_log_view())
        row.append(clear_button)
        page.append(row)
        self.serial_state = label("UART monitor idle · 115200 baud", "metric-caption")
        page.append(self.serial_state)
        self._metric_grid(page, [
            ("uart_fps", "Firmware FPS", "—", "Last firmware report"),
            ("uart_retries", "TX retries", "—", "Packets requiring retry"),
            ("uart_backoff", "Retry wait", "—", "Cumulative backoff"),
            ("uart_heap", "UART heap", "—", "Internal free heap"),
        ], columns=4)
        status_frame, status_box = card_box()
        status_box.append(label("LAST ESP32 STATUS SNAPSHOT", "eyebrow"))
        self.status_dump = Gtk.Label(label="No status snapshot received yet.", xalign=0, yalign=0)
        self.status_dump.set_selectable(True)
        self.status_dump.set_wrap(True)
        self.status_dump.add_css_class("mono")
        status_box.append(self.status_dump)
        page.append(status_frame)
        log_frame = Gtk.Frame(hexpand=True, vexpand=True)
        log_frame.add_css_class("metric-card")
        self.log_view = Gtk.TextView(editable=False, cursor_visible=False, monospace=True,
                                     wrap_mode=Gtk.WrapMode.NONE)
        self.log_view.add_css_class("mono")
        self.log_buffer = self.log_view.get_buffer()
        log_scroll = Gtk.ScrolledWindow(min_content_height=400, vexpand=True)
        log_scroll.set_child(self.log_view)
        log_frame.set_child(log_scroll)
        page.append(log_frame)

    def _navigate(self, _button, key):
        self.stack.set_visible_child_name(key)
        for name, item in self.nav_buttons.items():
            if name == key: item.add_css_class("suggested-action")
            else: item.remove_css_class("suggested-action")

    def _set_connection_state(self, text, state="neutral"):
        self.header_status.set_text(text)
        self.sidebar_status.set_text(f"●  {text}")
        self.sidebar_status.remove_css_class("success"); self.sidebar_status.remove_css_class("warning")
        if state == "connected": self.sidebar_status.add_css_class("success")
        elif state == "warning": self.sidebar_status.add_css_class("warning")
        self.footer_left.set_text(text)

    def _set_commission_controls(self, connected, paired):
        self.pair_button.set_sensitive(connected and not paired)
        self.provision_button.set_sensitive(connected and paired)

    def _set_udp_controls(self, connected):
        self.stream_button.set_sensitive(connected)
        self.stop_stream_button.set_sensitive(connected)
        self.single_button.set_sensitive(connected)
        self.flash_on_button.set_sensitive(connected)
        self.flash_off_button.set_sensitive(connected)
        self.profile_apply_button.set_sensitive(connected)

    def _task(self, function, success, failure=None, busy=None):
        if busy: busy.set_sensitive(False)
        future = self.executor.submit(function)
        def finished(done):
            try:
                result = done.result()
            except Exception as exc:
                GLib.idle_add(self._task_failed, str(exc), failure, busy)
            else:
                GLib.idle_add(self._task_succeeded, success, result, busy)
        future.add_done_callback(finished)

    def _task_failed(self, message, failure, busy):
        if busy: busy.set_sensitive(True)
        if failure: failure(message)
        else:
            self._log(f"ERROR: {message}")
            self._set_connection_state("Operation failed", "warning")
        return GLib.SOURCE_REMOVE

    def _task_succeeded(self, callback, result, busy):
        if busy: busy.set_sensitive(True)
        callback(result)
        return GLib.SOURCE_REMOVE

    def _ensure_ble(self):
        if self.ble is None:
            self.ble = BluezClient()
            self.ble.set_line_callback(lambda line: GLib.idle_add(self._on_ble_line, line))
        return self.ble

    def _scan_ble(self):
        self.ble_state.set_text("Scanning for BLE advertisements…")
        self._log("Starting BLE scan for service FFE0.")
        def done(devices):
            self.ble_devices = devices
            self.ble_device_list.remove_all()
            for device in devices:
                row = Gtk.ListBoxRow()
                box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
                box.set_margin_top(8); box.set_margin_bottom(8); box.set_margin_start(10); box.set_margin_end(10)
                box.append(label(device.name))
                rssi = f"{device.rssi} dBm" if device.rssi is not None else "RSSI unavailable"
                box.append(label(f"{device.address}  ·  {rssi}  ·  {'Connected' if device.connected else 'Advertising'}", "metric-caption"))
                row.set_child(box); row.device = device
                self.ble_device_list.append(row)
            if devices:
                self.ble_device_list.select_row(self.ble_device_list.get_row_at_index(0))
                self.ble_state.set_text(f"Found {len(devices)} compatible ESP32 device(s).")
            else:
                self.ble_state.set_text("No ESP32 found. It must be advertising in commissioning/recovery mode.")
            self._log(f"BLE scan complete: {len(devices)} compatible device(s).")
        self._task(lambda: self._ensure_ble().scan(10), done, busy=self.scan_ble_button)

    def _ble_selected(self, _list, row):
        self.selected_ble = getattr(row, "device", None) if row else None

    def _connect_ble(self):
        device = self.selected_ble
        if not device:
            self._scan_ble()
            return
        self.ble_state.set_text(f"Connecting to {device.address}…")
        def done(_):
            self.ble_state.set_text("BLE connected · FFE0 / FFE1 notify / FFE2 write")
            self.commissioning_status.set_text("Connected. Pair with the application code before sending Wi-Fi credentials.")
            self._set_commission_controls(True, self.ble.paired)
            self._set_connection_state("BLE connected", "connected")
            self.transport_label.set_text("BLE  Connected\nUDP  Offline\nUART  Idle")
            self._log(f"BLE GATT session established with {device.address}.")
            self._task(lambda: self.ble.request_status(5), self._on_status_line,
                       lambda message: self._log(f"BLE status query: {message}"))
        self._task(lambda: self._ensure_ble().connect(device.path), done, busy=self.connect_ble_button)

    def _pair_ble(self):
        code = self.pair_code.get_text().strip()
        self._task(lambda: self._ensure_ble().pair(code),
            lambda result: self._pair_complete(result),
            lambda message: self.commissioning_status.set_text(message),
            busy=self.pair_button)

    def _pair_complete(self, result):
        self.ble_state.set_text("Application paired · credentials can now be provisioned")
        self.commissioning_status.set_text(result)
        self._set_commission_controls(True, True)
        self._log("Application-level BLE pairing accepted by the ESP32.")

    def _scan_wifi(self):
        self.commissioning_status.set_text("Scanning nearby Wi-Fi networks…")
        self._task(lambda: scan_wifi(self.wifi_interface), self._wifi_scan_complete,
                   lambda message: self.commissioning_status.set_text(f"Wi-Fi scan failed: {message}"),
                   busy=self.wifi_scan_button)

    def _wifi_scan_complete(self, networks):
        self.wifi_networks = networks
        names = [f"{item.ssid}  ·  {item.signal}%  ·  {item.security}" for item in networks]
        if not names: names = ["No networks found"]
        self.wifi_dropdown.set_model(Gtk.StringList.new(names))
        current = next((index for index, item in enumerate(networks) if item.active), 0)
        if networks:
            self.wifi_dropdown.set_selected(current)
            self.ssid_entry.set_text(networks[current].ssid)
        self.commissioning_status.set_text(f"Found {len(networks)} visible Wi-Fi network(s) on {self.wifi_interface or 'the default adapter'}.")
        self._log(f"Wi-Fi scan found {len(networks)} network(s).")

    def _wifi_selection_changed(self, dropdown, _param):
        index = dropdown.get_selected()
        if 0 <= index < len(self.wifi_networks):
            self.ssid_entry.set_text(self.wifi_networks[index].ssid)

    def _provision_wifi(self):
        ssid = self.ssid_entry.get_text()
        password = self.password_entry.get_text()
        if not ssid:
            self.commissioning_status.set_text("Enter a Wi-Fi SSID first.")
            return
        if not self.ble or not self.ble.paired:
            self.commissioning_status.set_text("Connect and pair with the ESP32 first.")
            return
        self.commissioning_status.set_text("Sending Wi-Fi credentials over BLE, then rebooting the ESP32…")
        def provision_and_reboot():
            identity = self.ble.provision_wifi(ssid, password)
            ack = self.ble.reboot()
            self.ble.disconnect()
            return identity, ack
        def completed(result):
            identity, ack = result
            self.password_entry.set_text("")
            self.ble_state.set_text("Provisioned · reboot acknowledged · waiting for Wi-Fi")
            self.ble_identity.set_text("\n".join(identity) if identity else "Device identity not received")
            self.commissioning_status.set_text(f"{ack}. ESP32 is rebooting and joining {ssid}. UDP discovery starts in a few seconds.")
            self._set_commission_controls(False, False)
            self._set_connection_state("Waiting for ESP32 Wi-Fi", "warning")
            self._log(f"Wi-Fi credentials accepted for SSID {ssid!r}; reboot acknowledged.")
            GLib.timeout_add_seconds(5, self._auto_udp_discovery)
        self._task(provision_and_reboot, completed,
                   lambda message: self.commissioning_status.set_text(f"Provisioning failed: {message}"),
                   busy=self.provision_button)

    def _auto_udp_discovery(self):
        self._start_udp()
        return GLib.SOURCE_REMOVE

    def _refresh_network_header(self):
        try:
            ssid = current_ssid(self.wifi_interface)
            self.overview_link.set_text(f"Laptop Wi-Fi: {ssid or 'not associated'}  ·  Interface: {self.wifi_interface or 'unknown'}")
        except Exception as exc:
            self.overview_link.set_text(f"Laptop Wi-Fi: unavailable ({exc})")

    def _start_udp(self, target_ip=None):
        self._udp_generation += 1
        generation = self._udp_generation
        if self.udp:
            try:
                self.udp.stop_stream()
                self.udp.close()
            except Exception:
                pass
        self.udp = UdpStreamClient(
            on_state=lambda state: GLib.idle_add(self._dispatch_udp, generation, self._on_udp_state, state),
            on_frame=lambda frame, meta: GLib.idle_add(self._dispatch_udp, generation, self._on_frame, frame, meta),
            on_message=lambda message: GLib.idle_add(self._dispatch_udp, generation, self._on_udp_message, message),
            on_metrics=lambda values: GLib.idle_add(self._dispatch_udp, generation, self._on_metrics, values),
        )
        if not target_ip:
            target_ip = self.udp_ip_entry.get_text().strip() or self.ip_entry_stream.get_text().strip() or None
        self._log(f"Opening UDP receiver on port 8888; target={target_ip or 'broadcast discovery'}.")
        try:
            self.udp.start(target_ip)
        except Exception as exc:
            self._log(f"UDP start failed: {exc}")
            self._set_connection_state("UDP failed", "warning")
            return
        self._set_udp_controls(False)
        self.udp_state.set_text("UDP peer: discovering…")
        self.transport_label.set_text("BLE  Setup complete\nUDP  Discovering\nUART  Idle")
        self._navigate(None, "stream")

    def _dispatch_udp(self, generation, callback, *args):
        if generation == self._udp_generation:
            callback(*args)
        return GLib.SOURCE_REMOVE

    def _on_udp_state(self, state):
        self.udp_state.set_text(f"UDP peer: {state}")
        if state == "connected":
            self._set_connection_state(f"UDP connected · {self.udp.peer[0]}", "connected")
            self.transport_label.set_text("BLE  Commissioned\nUDP  Connected\nUART  Optional")
            self.commissioning_status.set_text(f"ESP32 discovered at {self.udp.peer[0]}:8888. The command and video channel is registered.")
            self._set_udp_controls(True)
            self._log(f"UDP peer connected: {self.udp.peer[0]}:8888.")
        elif state == "not-found":
            self._set_connection_state("ESP32 UDP peer not found", "warning")
            self._set_udp_controls(False)
        elif state == "disconnected":
            if self.udp is None: return
            self._set_udp_controls(False)
            self.transport_label.set_text("BLE  Available\nUDP  Offline\nUART  Optional")
        elif state == "discovering":
            self.udp_state.set_text("UDP peer: broadcasting discovery…")

    def _on_udp_message(self, message):
        self._log(message)
        if message.startswith("$STATUS:"):
            self._on_status_line(message)
        elif message.startswith("$CMD:video_profile="):
            self.profile_result_label.set_text(message.removeprefix("$CMD:").strip())
            if self.udp and self.udp.peer:
                try:
                    self.udp.send_command(0x09)
                except OSError as exc:
                    self._log(f"Status refresh after profile change failed: {exc}")

    def _on_ble_line(self, line):
        self._log(f"BLE ← {line}")
        if line.startswith("$ESP_MAC:") or line.startswith("$ESP_NAME:"):
            previous = self.ble_identity.get_text()
            self.ble_identity.set_text((previous + "\n" + line).strip())
        if line.startswith("$STATUS:"):
            self._on_status_line(line)

    def _on_status_line(self, line):
        status = parse_status_line(line)
        self.current_status.update(status)
        self.status_dump.set_text("\n".join(f"{key:<16} {value}" for key, value in sorted(status.items())))
        rssi = status.get("rssi")
        channel = status.get("channel", 0)
        if isinstance(channel, int) and channel > 0:
            self._metric_update("channel", str(channel), "Associated AP primary channel")
        else:
            self._metric_update("channel", "—", "Wi-Fi not associated")
        if isinstance(rssi, int) and rssi > -127:
            self._metric_update("rssi", f"{rssi} dBm", "ESP32 station RSSI")
        else:
            self._metric_update("rssi", "—", "Wi-Fi not associated")
        heap = status.get("heap")
        min_heap = status.get("min_heap")
        if heap is not None:
            self._metric_update("heap", f"{int(heap)/1024:.1f} KB",
                f"Minimum free: {int(min_heap or 0)/1024:.1f} KB")
        psram = status.get("psram")
        if psram is not None:
            self._metric_update("psram", f"{int(psram)/1024/1024:.1f} MB", "Detected camera PSRAM")
        profile = status.get("profile", "—")
        manual_profile = bool(status.get("manual_profile", 0))
        if isinstance(profile, int) and 0 <= profile <= 4:
            expected_selection = profile + 1 if manual_profile else 0
            if self.video_profile_dropdown.get_selected() != expected_selection:
                self.video_profile_dropdown.set_selected(expected_selection)
            mode_text = "Manual override" if manual_profile else "Automatic RSSI-adaptive"
            selected_text = self.video_profile_dropdown.get_model().get_string(
                self.video_profile_dropdown.get_selected()
            )
            self.profile_result_label.set_text(f"{mode_text} · {selected_text}")
        for key, field in (("capture", "capture_ms"), ("send", "send_ms"),
                           ("interval", "interval_ms")):
            value = status.get(field)
            self.live_stat_labels[key].set_text(f"{value} ms" if isinstance(value, int) else "—")
        profile_descriptions = {
            0: "XGA 1024×768 · Q20", 1: "SVGA 800×600 · Q24",
            2: "VGA 640×480 · Q28", 3: "QVGA 320×240 · Q40",
            4: "QQVGA 160×120 · Q40",
        }
        profile_description = profile_descriptions.get(profile, str(profile))
        frames, errors = status.get("frames", 0), status.get("errors", 0)
        valid = bool(status.get("sensor_valid", 0))
        sensor_present = bool(status.get("sensor", 0))
        spectrum = parse_spectrum(status.get("spectrum", ""))
        if not spectrum and valid:
            # Compatibility with the earlier two-channel status response.
            spectrum = {
                410: int(status.get("sensor_410", 0)),
                940: int(status.get("sensor_940", 0)),
            }
        self.spectrum_values = spectrum
        self._metric_update("sensor_state", "Available" if sensor_present else "Not detected",
                            "AS72651 + AS72652 + AS72653" if sensor_present else "Sensor probe unavailable")
        self._metric_update("sensor_valid", "Valid" if valid else "Waiting",
                            "Full spectrum sampled" if valid else "No valid sample in this snapshot")
        temperature_fields = (
            ("temp_as72653", "temp_as72653"),
            ("temp_as72652", "temp_as72652"),
            ("temp_as72651", "temp_as72651"),
        )
        for metric_key, status_key in temperature_fields:
            temperature = status.get(status_key)
            display = (f"{temperature} °C"
                       if sensor_present and valid and isinstance(temperature, int)
                       and temperature != -128 else "—")
            self._metric_update(metric_key, display, "Sensor-die temperature")
        for channel_name, wavelength, device in SPECTRAL_CHANNELS:
            raw_count = spectrum.get(wavelength)
            value = f"{raw_count:,}" if raw_count is not None else "—"
            detail = f"{device} · raw ADC count"
            self._metric_update(f"spectrum_{wavelength}", value, detail)
        if self.spectrum_values:
            self.spectrum_chart_status.set_text(
                f"{len(self.spectrum_values)} / 18 channels received · raw ADC counts"
            )
        else:
            self.spectrum_chart_status.set_text("Waiting for spectral channel data.")
        self.sensor_chart.queue_draw()
        wifi = status.get("wifi", "unknown")
        ip = status.get("ip", "—")
        camera = "ready" if status.get("camera", 0) else "not ready"
        self.health_summary.set_text(
            f"Wi-Fi: {wifi} · IP: {ip} · RSSI: {rssi if rssi is not None else '—'} dBm\n"
            f"Camera: {camera} · profile: {profile_description} · frames sent: {frames} · frame errors: {errors}\n"
            f"Wi-Fi channel: {channel if channel else '—'} · signal: {rssi if rssi is not None else '—'} dBm\n"
            f"Sensor: {'present' if sensor_present else 'not detected'} · stream: {'on' if status.get('stream') else 'off'} · flash: {'on' if status.get('flash') else 'off'}\n"
            f"Internal heap: {heap if heap is not None else '—'} bytes · PSRAM: {psram if psram is not None else '—'} bytes · BLE notify errors: {status.get('notify_errors', '—')}"
        )
        self._log(f"Status snapshot: {status}")

    def _metric_update(self, key, value, detail=None):
        widget = getattr(self, "metric_widgets", {}).get(key)
        if not widget: return
        widget[0].set_text(str(value))
        if detail is not None: widget[1].set_text(str(detail))

    def _request_status(self):
        if self.udp and self.udp.peer:
            try: self.udp.send_command(0x09)
            except Exception as exc: self._log(f"Status request failed: {exc}")
        elif self.ble and self.ble.tx_path:
            self._task(lambda: self.ble.request_status(5), self._on_status_line,
                       lambda message: self._log(f"BLE status request failed: {message}"))
        else:
            self._log("No connected BLE or UDP control channel.")

    def _send_udp_command(self, command):
        if not self.udp or not self.udp.peer:
            self._log("UDP peer is not connected.")
            return
        try:
            self.udp.send_command(command)
            self._log(f"UDP command sent: 0x{command:02x}")
        except Exception as exc:
            self._log(f"UDP command failed: {exc}")

    def _apply_video_profile(self):
        if not self.udp or not self.udp.peer:
            self.profile_result_label.set_text("Connect to the ESP32 UDP peer before changing its camera profile.")
            return
        selection = self.video_profile_dropdown.get_selected()
        profile = VIDEO_PROFILE_AUTO if selection == 0 else selection - 1
        try:
            self.udp.send_payload(encode_video_profile(profile))
        except Exception as exc:
            self.profile_result_label.set_text(f"Profile request failed: {exc}")
            return
        requested = "Automatic RSSI-adaptive" if selection == 0 else self.video_profile_dropdown.get_model().get_string(selection)
        self.profile_result_label.set_text(f"Requested: {requested}. Waiting for ESP32 acknowledgement…")
        self._log(f"Requested camera profile: {requested}.")

    def _stream_on(self):
        self._send_udp_command(CMD_STREAM_ON)
        self._log("Requested continuous camera streaming.")
    def _stream_off(self):
        self._send_udp_command(CMD_STREAM_OFF)
        self._log("Requested stream stop.")

    def _on_frame(self, frame, metadata):
        try:
            texture = Gdk.Texture.new_from_bytes(GLib.Bytes.new(frame))
            self.picture.set_paintable(texture)
            self.video_placeholder.set_visible(False)
            width, height = texture.get_width(), texture.get_height()
            self.video_dimensions.set_text(
                f"{width} × {height}  ·  {metadata['bytes'] / 1024:.1f} KB JPEG  ·  frame {metadata['frame_id']}"
            )
            self.frame_count += 1
            self._metric_update("frame", f"{width}×{height}", f"{metadata['bytes']/1024:.1f} KB JPEG")
            self._metric_update("fps", f"{metadata.get('fps', 0):.1f}", "Validated JPEG frames / second")
            self.live_stat_labels["bytes"].set_text(f"{metadata['bytes']/1024:.1f} KB")
            self.live_stat_labels["assembly"].set_text(f"{metadata['assembly_ms']:.1f} ms")
            self.live_stat_labels["recovered"].set_text(str(metadata["recovered"]))
            self.live_stat_labels["fps"].set_text(f"{metadata.get('fps', 0):.1f}")
            self.live_stat_labels["rssi"].set_text(f"{self.current_status.get('rssi', '—')} dBm")
            now = time.monotonic()
            if now - self._last_frame_log >= 1.0:
                self._last_frame_log = now
                self._log(f"FRAME id={metadata['frame_id']} {width}x{height} {metadata['bytes']}B "
                          f"assembly={metadata['assembly_ms']:.1f}ms FEC={metadata['recovered']}")
        except Exception as exc:
            self._log(f"Frame render failed: {exc}")

    def _on_metrics(self, values):
        self.latest_metrics = values
        self._metric_update("fps", f"{values.get('fps', 0):.1f}", "Validated JPEG frames per second")
        self._metric_update("throughput", f"{values.get('bandwidth_bps', 0)/1024:.1f} KB/s", "JPEG frame payload")
        self._metric_update("packet", str(values.get("datagrams", 0)),
                            f"Data {values.get('data_packets',0)} · parity {values.get('parity_packets',0)}")
        self._metric_update("recovery", str(values.get("recovered_fragments", 0)),
                            f"Incomplete frames: {values.get('incomplete_frames',0)}")
        self._metric_update("invalid", str(values.get("invalid_packets", 0)),
                            "Malformed or inconsistent datagrams")
        self.live_stat_labels["jitter"].set_text(f"{values.get('jitter_ms', 0):.1f} ms")
        self._last_ui_metrics = values

    def _draw_sensor_chart(self, _area, cr, width, height):
        left, right, top, bottom = 48, width - 16, 16, height - 42
        cr.set_line_width(1)
        cr.set_source_rgba(0.5, 0.55, 0.62, 0.28)
        for step in range(5):
            y = top + (bottom - top) * step / 4
            cr.move_to(left, y); cr.line_to(right, y); cr.stroke()

        points = [
            (name, wavelength, self.spectrum_values[wavelength])
            for name, wavelength, _device in SPECTRAL_CHANNELS
            if wavelength in self.spectrum_values
        ]
        if len(points) < 2:
            cr.set_source_rgba(0.65, 0.68, 0.72, 0.8)
            cr.move_to(left + 10, height / 2)
            cr.show_text("Waiting for valid spectral samples")
            return

        maximum = max(1, max(value for _name, _wavelength, value in points))
        cr.set_source_rgba(0.30, 0.62, 0.94, 0.95)
        cr.set_line_width(2.2)
        for index, (_name, _wavelength, value) in enumerate(points):
            x = left + (right - left) * index / max(1, len(points) - 1)
            y = bottom - (bottom - top) * value / maximum
            if index == 0:
                cr.move_to(x, y)
            else:
                cr.line_to(x, y)
        cr.stroke()

        cr.set_source_rgba(0.30, 0.62, 0.94, 1.0)
        for index, (_name, _wavelength, value) in enumerate(points):
            x = left + (right - left) * index / max(1, len(points) - 1)
            y = bottom - (bottom - top) * value / maximum
            cr.arc(x, y, 3.0, 0, 2 * math.pi)
            cr.fill()

        cr.set_source_rgba(0.65, 0.68, 0.72, 0.85)
        cr.move_to(4, top + 4); cr.show_text(str(maximum))
        cr.move_to(left, height - 10); cr.show_text(str(points[0][1]) + " nm")
        cr.move_to(right - 52, height - 10); cr.show_text(str(points[-1][1]) + " nm")

    def _refresh_serial_ports(self):
        ports = serial_ports()
        existing = self.serial_port_entry.get_text().strip() if hasattr(self, "serial_port_entry") else ""
        if hasattr(self, "serial_port_entry"):
            self.serial_port_entry.set_text(existing if existing in ports else (ports[0] if ports else ""))
        if hasattr(self, "serial_state"):
            self.serial_state.set_text("Available: " + (", ".join(ports) if ports else "no /dev/ttyUSB* or /dev/ttyACM* devices"))

    def _toggle_serial(self):
        if self.serial:
            self.serial.stop(); self.serial = None
            self.serial_button.set_label("Start UART monitor")
            self.serial_state.set_text("UART monitor stopped.")
            self.transport_label.set_text("BLE  Available\nUDP  Current\nUART  Idle")
            return
        port = self.serial_port_entry.get_text().strip()
        if not port:
            self.serial_state.set_text("Select a serial port first.")
            return
        self.serial = SerialMonitor(port, lambda line: GLib.idle_add(self._on_uart_line, line),
                                    lambda state: GLib.idle_add(self._on_serial_state, state))
        self._task(lambda: self.serial.start(), lambda _: self._serial_started(),
                   lambda message: self._on_serial_state(f"error: {message}"),
                   busy=self.serial_button)

    def _serial_started(self):
        self.serial_button.set_label("Stop UART monitor")
        self.serial_state.set_text(f"Reading {self.serial.port} at 115200 baud. DTR/RTS are held low to avoid auto-reset.")
        self.transport_label.set_text("BLE  Available\nUDP  Current\nUART  Monitoring")
        self._log(f"UART monitor opened {self.serial.port} at 115200 baud without toggling reset.")

    def _on_serial_state(self, state):
        self.serial_state.set_text(f"UART: {state}")
        if state.startswith("error"):
            self.serial_button.set_label("Start UART monitor")
            self.serial = None

    def _on_uart_line(self, line):
        self._log(f"UART  {line}")
        values = parse_uart_metrics(line)
        if values:
            self.uart_metrics.update(values)
            if "fps_x100" in values:
                self._metric_update("uart_fps", f"{values['fps_x100']/100:.2f}", "Firmware sender FPS window")
            if "retry_packets" in values:
                self._metric_update("uart_retries", str(values["retry_packets"]),
                                    f"Attempts: {values.get('retry_attempts', 0)}")
            if "retry_wait_ms" in values:
                self._metric_update("uart_backoff", f"{values['retry_wait_ms']} ms", "Accumulated retry delay")
            if "heap" in values:
                self._metric_update("uart_heap", f"{values['heap']/1024:.1f} KB", "UART firmware sample")
        if "operation=udp.stream" in line:
            self._log("Sender-side FPS/retry telemetry updated from UART.")

    def _log(self, message):
        stamp = time.strftime("%H:%M:%S")
        entry = f"[{stamp}] {message}"
        self.log_lines.append(entry)
        if hasattr(self, "log_buffer"):
            end = self.log_buffer.get_end_iter()
            self.log_buffer.insert(end, entry + "\n")
            line_count = self.log_buffer.get_line_count()
            if line_count > 2500:
                start = self.log_buffer.get_start_iter()
                remove = self.log_buffer.get_iter_at_line(line_count - 2500)
                self.log_buffer.delete(start, remove)
            mark = self.log_buffer.create_mark(None, self.log_buffer.get_end_iter(), False)
            self.log_view.scroll_mark_onscreen(mark)

    def _clear_log_view(self):
        self.log_lines.clear()
        self.log_buffer.set_text("")

    def _on_close(self, *_args):
        self._udp_generation += 1
        if self.udp:
            try: self.udp.stop_stream(); self.udp.close()
            except Exception: pass
        if self.serial:
            try: self.serial.stop()
            except Exception: pass
        if self.ble:
            try: self.ble.disconnect()
            except Exception: pass
        self.executor.shutdown(wait=False, cancel_futures=True)
        return False


class SpectruLenPorApplication(Adw.Application):
    def __init__(self):
        super().__init__(application_id="com.spectrulenpor.Lab",
                         flags=Gio.ApplicationFlags.DEFAULT_FLAGS)
        self.window = None

    def do_activate(self):
        if not self.window:
            self.window = SpectruLenPorWindow(self)
        self.window.present()


def main():
    Adw.init()
    app = SpectruLenPorApplication()
    return app.run(None)


if __name__ == "__main__":
    raise SystemExit(main())
