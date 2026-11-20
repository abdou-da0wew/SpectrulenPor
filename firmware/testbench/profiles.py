"""Real HIL profiles with progress callbacks and explicit configuration consent."""

import contextlib
import re
import tempfile
import uuid
from pathlib import Path

from .errors import TestbenchError
from .hil import suites
from .transport import WIRE
from .validation import wifi_credentials

CONTRACT_CASES = (
    "advertisement_and_gatt", "ble_stream_and_pause", "wifi_provisioning",
    "udp_single_frame", "udp_stream_and_pause", "udp_controls_and_peer_handover",
    "restart_and_nvs_recovery", "final_integrity",
)
BLE_CAPTURE_CASE = {"full": "paused_single_frame", "mobile-flow": "ble_single_frame"}


def _contract_verified(suite, profile, main):
    """Promote only a complete UART-backed contract from this suite's evidence."""
    if suite.uart is None or profile not in BLE_CAPTURE_CASE:
        return False
    if not all(record.get("ok") is True for record in suite.records):
        return False
    records = {record["name"]: record.get("details") for record in suite.records}
    required = CONTRACT_CASES + (BLE_CAPTURE_CASE[profile],)
    if profile == "full":
        required += ("flashlight_and_real_images",)
    if not all(isinstance(records.get(name), dict) for name in required):
        return False

    def positive(value):
        return type(value) is int and value > 0

    def image(details, allowed_sizes):
        dimensions = (details.get("width"), details.get("height")) if isinstance(details, dict) else None
        if isinstance(allowed_sizes, (set, frozenset, tuple)) and allowed_sizes and all(
            isinstance(item, tuple) for item in allowed_sizes
        ):
            size_ok = dimensions in allowed_sizes
        else:
            size_ok = dimensions == allowed_sizes
        return isinstance(details, dict) and positive(details.get("bytes")) and size_ok

    boot = records["wifi_provisioning"]
    recovery = records["restart_and_nvs_recovery"]
    controls = records["udp_controls_and_peer_handover"]
    integrity = records["final_integrity"]
    return (
        boot.get("software_reboot_observed") is True
        and boot.get("wifi") == "connected"
        and boot.get("ble_initialized") is False
        and positive(boot.get("ble_scan_seconds"))
        and recovery.get("hardware_reset_observed") is True
        and recovery.get("nvs_persistence_verified") is True
        and recovery.get("wifi_connected") is True
        and recovery.get("ble_initialized") is False
        and image(recovery.get("udp_image"), main.UDP_FRAME_SIZES)
        and image(records[BLE_CAPTURE_CASE[profile]], main.BLE_FRAME_SIZE)
        and image(records["udp_single_frame"], main.UDP_FRAME_SIZES)
        and positive(records["ble_stream_and_pause"].get("decoded_frames"))
        and positive(records["udp_stream_and_pause"].get("decoded_frames"))
        and all(controls.get(key) is True for key in (
            "flash_on_off", "invalid_and_other_peer_commands_not_executed",
            "unicast_handover", "original_peer_reclaimed",
        ))
        and all(type(integrity.get(key)) is int and integrity[key] == 0 for key in (
            "runtime_faults", "frame_errors", "notification_errors",
        ))
        and (profile != "full" or records["flashlight_and_real_images"].get("gpio_on_off") is True)
    )


@contextlib.contextmanager
def evidence_output(engine):
    """HIL JPEG evidence may be saved, but its raw UART log must never be saved."""
    if engine.output is not None:
        engine.output.mkdir(parents=True, exist_ok=True)
        yield engine.output
    else:
        with tempfile.TemporaryDirectory(prefix="spectrulenpor-frames-") as directory:
            yield Path(directory)


def run_profile(engine, profile, params):
    """Reuse the suite without spawning a competing hardware process or reader."""
    main, retry = suites()
    if profile in ("full", "missing-ap") and not params.get("confirm_configuration"):
        raise TestbenchError("TB_CONFIRM_CONFIGURATION", "CONFIRMATION_REQUIRED")
    if profile in ("full", "missing-ap") and not engine.uart_port:
        raise TestbenchError("TB_UART_REQUIRED", "UART_REQUIRED")
    if profile == "mobile-flow" and not engine.uart_port and not params.get("ip"):
        raise TestbenchError("TB_MANUAL_IP_REQUIRED", "INVALID_REQUEST")
    if profile in ("full", "mobile-flow"):
        # Fail before touching the fixture rather than treating omitted WiFi as
        # a passing, partially executed full/mobile profile.
        credentials = engine._credentials(params)
    else:
        credentials = None
    if engine.recovery_required:
        raise TestbenchError("TB_CONFIGURATION_RECOVERY_REQUIRED", "RECOVERY_REQUIRED")
    engine._acquire(want_ble=True)
    if engine.udp is not None:
        raise TestbenchError("TB_FRESH_BLE_SETUP_REQUIRED", "SETUP_REQUIRED")

    class ObservableSuite(main.HardwareSuite):
        def case(self, name, function):
            before = len(engine.state["job"]["records"])
            def observed():
                try:
                    details = function()
                    if name == "restart_and_nvs_recovery" and isinstance(details, dict):
                        # Preserve this boolean when credential-named fields are
                        # stripped from the public report. No credential value is exposed.
                        details = {**details, "nvs_persistence_verified":
                                   details.get("wifi_credentials_persisted") is True}
                    return details
                finally:
                    if self.udp is not None and not getattr(self.udp, "closed", False):
                        engine.udp = self.udp
                        engine._update(transport="udp", connected=True, ip=self.udp.peer[0])
                    elif self.phase == "setup":
                        engine._update(transport="ble", connected=self.client.rx is not None)
                    if self.phase == "wifi":
                        engine._update(phase="paused")

            try:
                return engine._record(name, observed)
            finally:
                if len(engine.state["job"]["records"]) > before:
                    self.records.append(dict(engine.state["job"]["records"][-1]))

        def provision(self, ssid, password):
            wifi_credentials(ssid, password)
            with engine.lock:
                engine.secrets.update(value for value in (ssid, password) if value)
            engine.recovery_required = True
            return super().provision(ssid, password)

        def wifi_connect(self):
            result = super().wifi_connect()
            engine._update(esp_mac=result["esp_mac"], esp_hostname=result["esp_hostname"], ip=result["ip"])
            return result

        def integrity(self):
            # The upstream suite reads uart.log here. Use the same assertions
            # against bounded in-memory capture, so credentials never reach disk.
            self.client.pump(1)
            status = self.status()
            WIRE.require(self.client.max_notification_bytes <= 500, "HIL_NOTIFICATION_TOO_LARGE")
            WIRE.require(self.client.protocol_errors == 0, "HIL_CLIENT_REASSEMBLY_ERRORS")
            WIRE.require(re.search(r"Guru Meditation|Brownout|abort\(\)|panic'ed|assert failed",
                                   self.uart.text(), re.I) is None, "HIL_UART_RUNTIME_FAULT")
            if status["sensor"] == "0":
                WIRE.require(not any(line.startswith("$UV:") for _, line in self.client.lines),
                             "HIL_FABRICATED_SENSOR_READING")
            return {"max_notification_bytes": self.client.max_notification_bytes,
                    "notifications": self.client.notifications,
                    "frame_errors": int(status["errors"]),
                    "notification_errors": int(status["notify_errors"]),
                    "heap_bytes": int(status["heap"]),
                    "minimum_internal_heap_bytes": int(status["min_heap"]), "runtime_faults": 0}

    def udp_factory(ip, port=WIRE.UDP_PORT):
        receiver = engine.udp_factory(ip, port, cooperate=engine.cooperate, on_frame=engine._publish)
        receiver.strict = True
        return receiver

    previous_udp = main.UdpFrames
    main.UdpFrames = udp_factory
    verified = False
    try:
        with evidence_output(engine) as output:
            suite = ObservableSuite(engine.client, output, credentials)
            suite.uart = engine.uart
            engine.suite = suite
            try:
                if profile == "full":
                    # Isolated boundary/reconfiguration/erase CASES require the
                    # explicit full-profile confirmation. No entry/cleanup erase
                    # is used to force the fixture into setup.
                    if engine.client.rx is not None:
                        engine.client.disconnect()
                    suite.run()
                    required = ("wifi_provisioning", "udp_single_frame", "restart_and_nvs_recovery")
                    if not all(any(record["name"] == name and record["ok"] for record in suite.records) for name in required):
                        raise TestbenchError("TB_FULL_WIFI_NOT_TESTED")
                    engine.recovery_required = False
                    engine._update(phase="disconnected", connected=False, transport=None)
                elif profile == "missing-ap":
                    _missing_ap(engine, suite, main, retry)
                else:
                    _mobile_flow(engine, suite, main, params)
                verified = _contract_verified(suite, profile, main)
            finally:
                suite.wifi = None
                if suite.udp is not None:
                    engine.udp = suite.udp if not getattr(suite.udp, "closed", False) else None
                engine.suite = None
    finally:
        main.UdpFrames = previous_udp
    engine.verifications.update(firmware=verified, mobile_contract=verified)


def _fresh_setup(engine, suite):
    if engine.client.rx is not None:
        engine.client.disconnect()
    mark = engine.uart.reset()
    engine.uart.wait(r"operation=boot.mode mode=ble_setup ble=1", mark,
                     code="HIL_SETUP_REQUIRES_CLEAN_NVS")
    engine.uart.wait(r"operation=ble.advertise", mark, code="HIL_SETUP_ADVERTISEMENT_MISSING")
    suite.case("advertisement_and_gatt", suite.advertisement_and_gatt)
    WIRE.require(suite.wifi_config_get() == "", "HIL_SETUP_REQUIRES_CLEAN_NVS")
    engine._update(phase="ble_setup", connected=True, transport="ble")


def _missing_ap(engine, suite, main, retry):
    _fresh_setup(engine, suite)
    attempts, per_attempt = retry.retry_settings()
    engine.client.pair(WIRE.BLE_PAIRING_CODE)
    missing_ssid = "SLP-HIL-" + uuid.uuid4().hex[:12]
    suite.provision(missing_ssid, main.TEST_PASSWORD)
    WIRE.require(suite.wifi_config_get() == missing_ssid, "HIL_WIFI_CONFIG_MISMATCH")
    WIRE.require(suite.status()["wifi"] == "disconnected", "HIL_WIFI_STARTED_DURING_SETUP")
    mark = engine.uart.mark()
    engine.client.reboot()
    engine._update(phase="rebooting")
    engine.client.wait(lambda: not engine.client.manager.GetManagedObjects().get(
        engine.client.device_path, {}).get(WIRE.DEVICE, {}).get("Connected", False),
        main.REPLY_TIMEOUT, "HIL_REBOOT_DID_NOT_DISCONNECT_BLE")
    engine.client.disconnect()
    engine._update(connected=False, transport=None)
    suite.phase = "wifi"
    suite.case("missing_ap_retry_exhaustion", lambda: retry.missing_ap_evidence(
        engine.uart, engine.client, mark, attempts, per_attempt, True))
    mark = engine.uart.reset()
    suite.case("missing_ap_nvs_persistence", lambda: retry.missing_ap_evidence(
        engine.uart, engine.client, mark, min(2, attempts), per_attempt, False))
    # This successful negative profile intentionally leaves an unreachable
    # configuration. The operator, not cancellation/cleanup, recovers NVS.
    engine.recovery_required = True
    engine._update(phase="disconnected", connected=False, transport=None)


def _mobile_flow(engine, suite, main, params):
    if engine.uart is not None:
        _fresh_setup(engine, suite)
        suite.case("ble_single_frame", suite.single_frame)
        suite.case("ble_stream_and_pause", suite.ble_stream)
        suite.case("wifi_provisioning", suite.wifi_connect)
        suite.case("udp_single_frame", suite.udp_single)
        suite.case("udp_stream_and_pause", suite.udp_stream)
        suite.case("udp_controls_and_peer_handover", suite.udp_controls_and_peer)
        suite.case("restart_and_nvs_recovery", suite.restart)
        suite.case("final_integrity", suite.integrity)
        engine.recovery_required = False
        engine._update(phase="paused")
        return
    # Without UART, Linux can prove BLE acknowledgments and decoded UDP/control
    # behavior but cannot prove boot/NVS persistence or Android integration.
    engine._connect({})
    WIRE.require(suite.wifi_config_get() == "", "HIL_SETUP_REQUIRES_CLEAN_NVS")
    engine._record("ble_capture_contract", lambda: _ble_capture(engine))
    engine._record("ble_pair_and_provision", lambda: _provision_record(
        engine, {"ssid": suite.wifi[0], "password": suite.wifi[1]}))
    engine._record("reboot_disconnect", lambda: _reboot_record(engine))
    if not params.get("ip"):
        raise TestbenchError("TB_MANUAL_IP_REQUIRED", "INVALID_REQUEST")
    engine._record("decoded_udp_attach", lambda: _attach_record(engine, params["ip"]))
    engine._smoke({})
    engine._event("nvs_persistence", "pending", "TB_UART_REQUIRED")


def _ble_capture(engine):
    engine._control(WIRE.CMD_STREAM_OFF)
    engine._drain()
    engine._control(WIRE.CMD_SINGLE_FRAME)
    _, data = engine._next_frame()
    engine._quiet()
    return {"decoded_jpeg": True, "bytes": len(data)}


def _provision_record(engine, params):
    engine._setup(params, reboot=False)
    return {"exact_acknowledgment": True, "fresh_device_identity": True}


def _reboot_record(engine):
    engine._reboot()
    return {"exact_reboot_acknowledgment": True, "actual_ble_disconnect": True,
            "boot_observed": False, "nvs_persistence_verified": False}


def _attach_record(engine, ip):
    engine._attach(ip)
    return {"decoded_jpeg": True, "ip": ip}
