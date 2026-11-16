"""Exclusive hardware worker and immutable snapshots shared by every frontend."""

import copy
import json
import queue
import re
import tempfile
import threading
import time
import uuid
from collections import deque
from datetime import datetime, timezone
from pathlib import Path

from .errors import TestbenchError, safe_error
from .hardware_lock import HardwareLock
from .hil import suites
from .settings import (DEFAULT_ADAPTER, DEFAULT_SOAK_SECONDS, FPS_WINDOW_SECONDS,
                       FRAME_TIMEOUT_SECONDS, MAX_EVENTS, MAX_RECORDS, QUIET_SECONDS,
                       LINK_CHECK_SECONDS, UART_OPEN_OBSERVE_SECONDS, WORKER_POLL_SECONDS)
from .transport import MemoryUART, UdpReceiver, WIRE, bluez_client, jpeg_dimensions
from .validation import MAC_PATTERN, HOSTNAME_PATTERN, action_request, adapter_name, peer_ip, wifi_credentials


def timestamp():
    return datetime.now(timezone.utc).isoformat()


class HardwareEngine:
    """The worker owns BlueZ, UART and UDP; HTTP threads only queue or read."""

    def __init__(self, adapter=DEFAULT_ADAPTER, uart=None, output=None, *,
                 client_factory=bluez_client, uart_factory=MemoryUART,
                 udp_factory=UdpReceiver, lock_factory=HardwareLock,
                 decoder=jpeg_dimensions):
        self.adapter = adapter_name(adapter)
        self.uart_port = uart
        self.output = Path(output) if output else None
        self.client_factory, self.uart_factory = client_factory, uart_factory
        self.udp_factory, self.lock_factory, self.decoder = udp_factory, lock_factory, decoder
        self.client = self.uart = self.udp = self.hardware_lock = None
        self.lock = threading.RLock()
        self.commands = queue.Queue(maxsize=1)
        self.stop = threading.Event()  # Process shutdown is never reset by job admission.
        self.cancelled = threading.Event()
        self.thread = None
        self.owner = None
        self.cleaning = False
        self.suite = None
        self.recovery_required = False
        self.secrets = set()
        self.latest = None
        self.frame_stamp = None
        self.frame_times = deque()
        self.protocol_errors = 0
        self.last_link_check = 0
        self.receive_diagnostics = None
        self.uart_observation_mark = 0
        self.uart_open_pending = False
        self.verifications = {"firmware": False, "mobile_contract": False,
                              "android": "pending", "sensor": "pending"}
        self.state = {
            "phase": "disconnected", "busy": False, "connected": False,
            "transport": None, "esp_mac": None, "esp_hostname": None, "ip": None,
            "frame": {"sequence": 0, "age_seconds": None, "bytes": 0, "width": None, "height": None},
            "metrics": {"frames": 0, "received_fps": 0, "incomplete_frames": 0, "datagrams": 0},
            "events": [], "job": None, "error": None,
            "capabilities": {"uart": bool(uart)},
        }

    def start(self):
        with self.lock:
            if self.thread is None:
                self.thread = threading.Thread(target=self._worker, name="testbench-hardware", daemon=True)
                self.thread.start()
        return self

    def close(self):
        self.stop.set()
        self.cancelled.set()
        if self.thread is not None:
            # Cooperative I/O deadlines are finite; never release a lock while its
            # worker might still own an in-flight write.
            self.thread.join()

    def _public_details(self, value):
        if isinstance(value, dict):
            return {str(key): self._public_details(item) for key, item in value.items()
                    if not re.search(r"ssid|password|credential|psk|raw|uart_text", str(key), re.I)}
        if isinstance(value, (tuple, list)):
            return [self._public_details(item) for item in value]
        if isinstance(value, str):
            for secret in self.secrets:
                if secret and secret in value:
                    value = value.replace(secret, "[redacted]")
            return value[:1000]
        if value is None or type(value) in (bool, int, float):
            return value
        return None

    def snapshot(self):
        with self.lock:
            result = copy.deepcopy(self.state)
            now = time.monotonic()
            if self.frame_stamp is not None:
                result["frame"]["age_seconds"] = round(max(0, now - self.frame_stamp), 3)
            recent = [stamp for stamp in self.frame_times if now - stamp <= FPS_WINDOW_SECONDS]
            if len(recent) < 2:
                result["metrics"]["received_fps"] = 0
            return result

    def frame(self):
        with self.lock:
            return self.latest, self.state["frame"]["sequence"]

    def report(self):
        with self.lock:
            job = copy.deepcopy(self.state["job"])
            return {
                "timestamp": timestamp(),
                "ok": bool(job and job["status"] == "passed" and self.state["error"] is None),
                "job": job, "cases": copy.deepcopy(job["records"] if job else []),
                "metrics": copy.deepcopy(self.state["metrics"]),
                "error": copy.deepcopy(self.state["error"]),
                "configuration_may_require_recovery": self.recovery_required,
                "verifications": dict(self.verifications),
                "mobile_contract_platform": "linux", "android_verified": False,
                "sensor_verified": False,
                "receive_diagnostics": copy.deepcopy(self.receive_diagnostics),
                "events": copy.deepcopy(self.state["events"]),
            }

    def _update(self, **values):
        with self.lock:
            self.state.update(values)

    def _run_failure(self, failure):
        """Invalidate final run health without replacing an earlier primary error."""
        with self.lock:
            self.verifications.update(firmware=False, mobile_contract=False)
            self.state["phase"] = "error"
            if self.state["error"] is None:
                self.state["error"] = failure.public()

    def _event(self, operation, outcome, code=None, details=None):
        event = {"timestamp": timestamp(), "operation": operation, "outcome": outcome}
        if code:
            event["code"] = code
        with self.lock:
            if details is not None:
                event["details"] = self._public_details(details)
            self.state["events"].append(event)
            del self.state["events"][:-MAX_EVENTS]

    def submit(self, body):
        action, params = action_request(body)
        with self.lock:
            if self.stop.is_set():
                raise TestbenchError("TB_ENGINE_CLOSED", "INTERNAL", 409)
            if action == "cancel":
                if not self.state["busy"]:
                    raise TestbenchError("TB_NO_ACTIVE_JOB", "INVALID_REQUEST", 409)
                self.cancelled.set()
                return self.state["job"]["id"]
            if self.state["busy"]:
                raise TestbenchError("TB_BUSY", "BUSY", 409)
            phase = self.state["phase"]
            if action in ("stream", "single", "flash") and not self.state["connected"]:
                raise TestbenchError("TB_NOT_CONNECTED", "NOT_CONNECTED", 409)
            if action == "setup":
                if self.recovery_required:
                    raise TestbenchError("TB_CONFIGURATION_RECOVERY_REQUIRED", "RECOVERY_REQUIRED", 409)
                if phase not in ("ble_setup", "paired"):
                    raise TestbenchError("TB_BLE_SETUP_REQUIRED", "SETUP_REQUIRED", 409)
            if action == "reboot" and phase != "provisioned":
                raise TestbenchError("TB_PROVISIONED_REQUIRED", "SETUP_REQUIRED", 409)
            job_id = uuid.uuid4().hex
            self.cancelled.clear()
            if self.stop.is_set():
                raise TestbenchError("TB_CANCELLED", "CANCELLED")
            self.state["busy"] = True
            self.state["error"] = None
            self.state["job"] = {"id": job_id, "profile": params.get("profile", action),
                                 "status": "queued", "records": []}
            self.commands.put_nowait((action, params))
        self.start()
        return job_id

    def _assert_owner(self):
        if threading.get_ident() != self.owner:
            raise TestbenchError("TB_HARDWARE_THREAD_VIOLATION", "INTERNAL")

    def cooperate(self):
        self._assert_owner()
        if not self.cleaning and (self.cancelled.is_set() or self.stop.is_set()):
            raise TestbenchError("TB_CANCELLED", "CANCELLED")
        if self.uart is not None:
            self.uart.poll()

    def _worker(self):
        self.owner = threading.get_ident()
        try:
            # An admitted job must reach a terminal state even if shutdown arrives
            # between queue insertion and worker startup. It cannot acquire hardware.
            while not self.stop.is_set() or not self.commands.empty():
                try:
                    action, params = self.commands.get(timeout=WORKER_POLL_SECONDS)
                except queue.Empty:
                    if self.stop.is_set():
                        break
                    try:
                        self._idle_pump()
                    except Exception as error:
                        failure = safe_error(error)
                        if self.stop.is_set() and failure.code == "TB_CANCELLED":
                            break
                        self._run_failure(failure)
                        self._event("receive", "failure", failure.code)
                        self._cleanup()
                        self._save_report()
                    continue
                with self.lock:
                    self.state["job"]["status"] = "running"
                try:
                    self.cooperate()
                    self._execute(action, params)
                    with self.lock:
                        self.state["job"]["status"] = "passed"
                    self._event(action, "success")
                except Exception as error:
                    failure = safe_error(error)
                    with self.lock:
                        self.state["job"]["status"] = "cancelled" if failure.code == "TB_CANCELLED" else "failed"
                        self.state["job"]["error"] = failure.public()
                    self._run_failure(failure)
                    self._event(action, "failure", failure.code)
                    self._cleanup()
                finally:
                    params.clear()
                    self._update(busy=False)
                    self.commands.task_done()
                    self._save_report()
        finally:
            try:
                self._cleanup()
            finally:
                self._save_report()

    def _acquire(self, want_ble=False):
        self.cooperate()
        if self.hardware_lock is None:
            self.hardware_lock = self.lock_factory(self.adapter, self.uart_port)
            try:
                self.hardware_lock.acquire()
            except Exception:
                self.hardware_lock = None
                raise
        if self.uart_port and self.uart is None:
            self.uart = self.uart_factory(self.uart_port, cooperate=self.cooperate)
            self.uart_observation_mark = self.uart.mark()
            self.uart.__enter__()
            self.uart_open_pending = True
        if want_ble and self.client is None:
            self.client = self.client_factory(self.adapter, self.cooperate, self._publish)

    def _idle_pump(self):
        if self.hardware_lock is None:
            return
        self.cooperate()
        if self.client is not None:
            self.client.pump()
            now = time.monotonic()
            if self.client.rx is not None and now - self.last_link_check >= LINK_CHECK_SECONDS:
                self.last_link_check = now
                connected = self.client.manager.GetManagedObjects().get(
                    self.client.device_path, {}).get(WIRE.DEVICE, {}).get("Connected", False)
                if not connected:
                    self._event("ble_link", "disconnected", "TB_BLE_DISCONNECTED")
                    self._cleanup()
                    self._update(phase="disconnected")
                    return
            while self.client.frames:
                stamp, data = self.client.frames.popleft()
                self._publish(stamp, data, "ble")
        if self.udp is not None:
            self.udp.poll()
            while self.udp.ready:
                stamp, data = self.udp.ready.popleft()
                self._publish(stamp, data, "udp")
            self._udp_metrics()

    def _udp_metrics(self):
        if self.udp is not None:
            with self.lock:
                self.state["metrics"]["datagrams"] = self.udp.datagrams
                self.state["metrics"]["incomplete_frames"] = self.udp.dropped_frames
                self.protocol_errors = self.udp.assembly.protocol_errors
                self.receive_diagnostics = {
                    "datagrams": self.udp.datagrams, "packets": self.udp.packets,
                    "incomplete_frames": self.udp.dropped_frames,
                    "protocol_errors": self.udp.assembly.protocol_errors,
                    "in_progress_chunks": len(self.udp.assembly.parts),
                    "expected_chunks": self.udp.assembly.total,
                    "last_incomplete": copy.deepcopy(getattr(self.udp.assembly, "last_incomplete", None)),
                }

    def _publish(self, stamp, data, transport):
        width, height = self.decoder(data)
        with self.lock:
            self.latest = bytes(data)
            self.frame_stamp = stamp
            self.frame_times.append(stamp)
            while self.frame_times and stamp - self.frame_times[0] > FPS_WINDOW_SECONDS:
                self.frame_times.popleft()
            count = len(self.frame_times)
            span = stamp - self.frame_times[0] if count else 0
            metrics = self.state["metrics"]
            metrics["frames"] += 1
            metrics["received_fps"] = round((count - 1) / span, 2) if span > 0 else 0
            self.state["frame"] = {"sequence": metrics["frames"], "age_seconds": 0,
                                    "bytes": len(data), "width": width, "height": height}
            self.state["transport"] = transport
            self.state["connected"] = True
        self._udp_metrics()

    def _clear_latest(self):
        with self.lock:
            self.latest = self.frame_stamp = None
            self.frame_times.clear()
            self.state["frame"].update(age_seconds=None, bytes=0, width=None, height=None)

    def _connect(self, params):
        requested_adapter = params.get("adapter", self.adapter)
        if self.hardware_lock is not None and requested_adapter != self.adapter:
            self._cleanup()
        self.adapter = requested_adapter
        self._acquire(want_ble=True)
        if self.udp is not None:
            raise TestbenchError("TB_DISCONNECT_BEFORE_BLE", "SETUP_REQUIRED", 409)
        self.client.connect()
        status = self.client.status()
        if status.get("bt") != "1":
            raise TestbenchError("TB_BLE_SETUP_REQUIRED", "SETUP_REQUIRED")
        self._clear_latest()
        self._update(phase="ble_setup", transport="ble", connected=True, ip=None,
                     esp_mac=None, esp_hostname=None)
        self.client.pair(WIRE.BLE_PAIRING_CODE)
        self._update(phase="paired")

    def _credentials(self, params):
        if params.get("wifi_from_nm"):
            main, _ = suites()
            credentials = main.network_manager_credentials()
        else:
            if "ssid" not in params:
                raise TestbenchError("TB_WIFI_CREDENTIALS_REQUIRED", "INVALID_WIFI")
            credentials = (params.get("ssid"), params.get("password", ""))
        credentials = wifi_credentials(*credentials)
        with self.lock:
            self.secrets.update(value for value in credentials if value)
        return credentials

    def _setup(self, params, *, reboot=True):
        credentials = self._credentials(params)
        self.cooperate()
        if not self.client.paired:
            self.client.pair(WIRE.BLE_PAIRING_CODE)
        self._update(phase="paired")
        self.client.esp_mac = self.client.esp_hostname = None
        since = time.monotonic()
        self.recovery_required = True
        self._event("configuration", "started", "TB_CONFIGURATION_RECOVERY_REQUIRED")
        self.client.wifi_config_put(*credentials)
        self.cooperate()
        mac = self.client.line("$ESP_MAC:", since).removeprefix("$ESP_MAC:")
        hostname = self.client.line("$ESP_NAME:", since).removeprefix("$ESP_NAME:")
        if not MAC_PATTERN.fullmatch(mac) or not HOSTNAME_PATTERN.fullmatch(hostname):
            raise TestbenchError("TB_INVALID_DEVICE_IDENTITY")
        self.cooperate()
        self._update(phase="provisioned", esp_mac=mac, esp_hostname=hostname)
        self._event("setup", "success", details={"esp_mac": mac, "esp_hostname": hostname})
        if reboot:
            self._reboot()

    def _reboot(self):
        mark = self.uart.mark() if self.uart is not None else None
        self.client.reboot()
        self._update(phase="rebooting")
        self.client.wait(lambda: not self.client.manager.GetManagedObjects().get(
            self.client.device_path, {}).get(WIRE.DEVICE, {}).get("Connected", False),
            FRAME_TIMEOUT_SECONDS, "HIL_REBOOT_DID_NOT_DISCONNECT_BLE")
        self.client.disconnect()
        self._clear_latest()
        self._update(connected=False, transport=None)
        if self.uart is not None:
            main, _ = suites()
            self.uart.wait(r"rst:.*RESET", mark, code="HIL_REBOOT_NOT_OBSERVED")
            self.uart.wait(r"operation=boot.mode mode=wifi_only ble=0", mark,
                           code="HIL_WIFI_ONLY_BOOT_MISSING")
            self.uart.wait(r"operation=boot.ready camera=1", mark, code="HIL_CAMERA_BOOT_FAILED")
            match = self.uart.wait(r"operation=wifi.got_ip ip=([0-9.]+)", mark,
                                   main.WIFI_TIMEOUT, "HIL_WIFI_CONNECT_TIMEOUT")
            ip = peer_ip(match.group(1))
            text = self.uart.text(mark)
            if "operation=ble.init" in text or "operation=ble.advertise" in text:
                raise TestbenchError("HIL_BLE_STARTED_IN_WIFI_MODE")
            self._attach(ip)

    def _attach(self, ip):
        self._acquire()
        self._await_uart_wifi(ip)
        if self.client is not None and self.client.rx is not None:
            self.client.disconnect()
        if self.udp is not None:
            self.udp.close()
        self._clear_latest()
        self._update(connected=False, transport=None, ip=ip)
        self.udp = self.udp_factory(ip, cooperate=self.cooperate, on_frame=self._publish)
        self.udp.command(bytes([WIRE.CMD_SINGLE_FRAME]))
        self.udp.next_frame(timeout=FRAME_TIMEOUT_SECONDS)
        self.cooperate()
        self.recovery_required = False
        self._update(phase="wifi_ready", connected=True, transport="udp")
        self._event("attach", "success", details={"decoded_jpeg": True, "ip": ip})

    def _await_uart_wifi(self, ip):
        """Opening some UART shields resets EN; do not race that fresh boot."""
        if self.uart is None:
            return
        since = self.uart_observation_mark
        reboot = re.compile(r"rst:|POWERON_RESET|operation=boot.mode")
        deadline = time.monotonic() + (UART_OPEN_OBSERVE_SECONDS if self.uart_open_pending else 0)
        while True:
            self.cooperate()
            text = self.uart.text(since)
            if reboot.search(text) or time.monotonic() >= deadline:
                break
            time.sleep(WORKER_POLL_SECONDS)
        self.uart_open_pending = False
        if reboot.search(text):
            main, _ = suites()

            def fresh_ready(capture):
                boots = list(reboot.finditer(capture))
                tail = capture[boots[-1].start():] if boots else capture
                if "operation=boot.mode mode=ble_setup ble=1" in tail:
                    raise TestbenchError("TB_FRESH_BLE_SETUP_REQUIRED", "SETUP_REQUIRED")
                if "operation=boot.mode mode=wifi_only ble=0" not in tail or "operation=boot.ready camera=1" not in tail:
                    return None
                match = re.search(r"operation=wifi.got_ip ip=([0-9.]+)", tail)
                if match is None or "UDP socket bound on port" not in tail[match.end():]:
                    return None
                observed = peer_ip(match.group(1))
                if observed != ip:
                    raise TestbenchError("TB_UART_IP_MISMATCH")
                if "operation=ble.init" in tail or "operation=ble.advertise" in tail:
                    raise TestbenchError("HIL_BLE_STARTED_IN_WIFI_MODE")
                return {"fresh_wifi_boot_observed": True, "udp_listener_observed": True}

            evidence = self.uart.wait_for(fresh_ready, since, main.WIFI_TIMEOUT,
                                          "HIL_WIFI_CONNECT_TIMEOUT", self.cooperate)
            self._event("uart_wifi_boot", "success", details=evidence)
        self.uart_observation_mark = self.uart.mark()

    def _control(self, code):
        acknowledgments = {WIRE.CMD_STREAM_OFF: "$CMD:stream_off", WIRE.CMD_STREAM_ON: "$CMD:stream_on",
                           WIRE.CMD_SINGLE_FRAME: "$CMD:single_frame", WIRE.CMD_FLASH_ON: "$CMD:flash_on",
                           WIRE.CMD_FLASH_OFF: "$CMD:flash_off"}
        if self.udp is not None:
            self.udp.command(bytes([code]))
        elif self.client is not None and self.client.rx is not None:
            self.client.command(code, acknowledgments[code])
        else:
            raise TestbenchError("TB_NOT_CONNECTED", "NOT_CONNECTED", 409)

    def _next_frame(self):
        if self.udp is not None:
            return self.udp.next_frame(timeout=FRAME_TIMEOUT_SECONDS)
        return self.client.frame(timeout=FRAME_TIMEOUT_SECONDS)

    def _drain(self):
        if self.udp is not None:
            self.udp.drain()
        else:
            self.client.clear_frames()

    def _quiet(self):
        deadline = time.monotonic() + QUIET_SECONDS
        datagrams = self.udp.datagrams if self.udp else None
        while time.monotonic() < deadline:
            self.cooperate()
            if self.client is not None:
                self.client.pump()
            if self.udp is not None:
                self.udp.poll()
                if self.udp.ready or self.udp.datagrams != datagrams:
                    raise TestbenchError("HIL_UDP_UNEXPECTED_FRAGMENTS")
            elif self.client.frames:
                raise TestbenchError("HIL_SINGLE_FRAME_RESUMED_STREAM")
            time.sleep(WORKER_POLL_SECONDS)
        self._udp_metrics()

    def _record(self, name, function):
        self.cooperate()
        started = time.monotonic()
        record = {"name": name, "ok": False}
        try:
            details = function()
            if not isinstance(details, dict):
                raise TestbenchError("HIL_CASE_MISSING_EVIDENCE")
            record.update(ok=True, details=self._public_details(details))
            return details
        except Exception as error:
            record["code"] = safe_error(error).code
            raise
        finally:
            record["seconds"] = round(time.monotonic() - started, 3)
            with self.lock:
                self.state["job"]["records"].append(record)
                del self.state["job"]["records"][:-MAX_RECORDS]
            self._event(name, "success" if record["ok"] else "failure", record.get("code"))

    def _smoke(self, params):
        if not self.state["connected"]:
            if params.get("ip"):
                self._attach(params["ip"])
            else:
                self._connect({})

        def single():
            self._control(WIRE.CMD_STREAM_OFF)
            self._drain()
            self._control(WIRE.CMD_SINGLE_FRAME)
            _, data = self._next_frame()
            self._quiet()
            return {"decoded_jpeg": True, "bytes": len(data), "transport": self.state["transport"]}

        self._record("paused_single_frame", single)

        def stream():
            self._control(WIRE.CMD_STREAM_ON)
            times = [self._next_frame()[0] for _ in range(3)]
            self._control(WIRE.CMD_STREAM_OFF)
            self._drain()
            self._quiet()
            return {"decoded_frames": len(times), "pause_observed": True,
                    "received_fps": round((len(times) - 1) / (times[-1] - times[0]), 2) if times[-1] > times[0] else 0}

        self._record("stream_and_pause", stream)

        def flash():
            verified = []
            images = []
            for enabled in (True, False):
                self._control(WIRE.CMD_FLASH_ON if enabled else WIRE.CMD_FLASH_OFF)
                if self.udp is None:
                    status = self.client.status()
                    if status.get("flash") != ("1" if enabled else "0"):
                        raise TestbenchError("HIL_FLASH_STATE_MISMATCH")
                    verified.append(True)
                elif self.uart is not None:
                    # UDP has no authenticated acknowledgment. Fresh UART status
                    # is evidence; JPEG brightness alone cannot prove GPIO state.
                    mark = self.uart.mark()
                    match = self.uart.wait(r"\$STATUS:([^\r\n]+)", mark,
                                          FRAME_TIMEOUT_SECONDS, "HIL_UART_STATUS_TIMEOUT")
                    status = dict(pair.split("=", 1) for pair in match.group(1).split(",") if "=" in pair)
                    if status.get("flash") != ("1" if enabled else "0"):
                        raise TestbenchError("HIL_FLASH_STATE_MISMATCH")
                    verified.append(True)
                else:
                    verified.append(False)
                self._drain()
                self._control(WIRE.CMD_SINGLE_FRAME)
                _, data = self._next_frame()
                images.append(len(data))
            return {"flash_commands_sent": True, "gpio_state_verified": all(verified),
                    "decoded_images": len(images), "image_bytes": images}

        self._record("flash_controls_and_images", flash)
        if self.protocol_errors or self.client is not None and self.client.protocol_errors:
            raise TestbenchError("TB_REASSEMBLY_ERRORS")
        self._update(phase="paused")

    def _soak(self, params):
        if not self.state["connected"]:
            if params.get("ip"):
                self._attach(params["ip"])
            else:
                self._connect({})
        duration = params.get("duration", DEFAULT_SOAK_SECONDS)

        def observe():
            before = self.state["metrics"]["frames"]
            self._control(WIRE.CMD_STREAM_ON)
            started, last = time.monotonic(), time.monotonic()
            deadline = started + duration
            while time.monotonic() < deadline:
                self._idle_pump()
                if self.state["metrics"]["frames"] > before:
                    last = self.frame_stamp
                if time.monotonic() - last > FRAME_TIMEOUT_SECONDS:
                    raise TestbenchError("TB_FRAME_TIMEOUT", "FRAME_TIMEOUT")
                time.sleep(WORKER_POLL_SECONDS)
            elapsed = time.monotonic() - started
            self._control(WIRE.CMD_STREAM_OFF)
            self._drain()
            self._quiet()
            frames = self.state["metrics"]["frames"] - before
            if not frames:
                raise TestbenchError("TB_FRAME_TIMEOUT", "FRAME_TIMEOUT")
            if self.protocol_errors or self.client is not None and self.client.protocol_errors:
                raise TestbenchError("TB_REASSEMBLY_ERRORS")
            return {"requested_seconds": duration, "seconds_observed": round(elapsed, 3),
                    "decoded_frames": frames, "received_fps": round(frames / elapsed, 2),
                    "incomplete_frames": self.state["metrics"]["incomplete_frames"],
                    "protocol_errors": self.protocol_errors, "pause_observed": True}

        self._record("decoded_frame_soak", observe)
        self._update(phase="paused")

    def _execute(self, action, params):
        if action == "connect":
            self._connect(params)
        elif action == "setup":
            self._setup(params)
        elif action == "reboot":
            self._reboot()
        elif action == "attach":
            self._attach(params["ip"])
        elif action == "stream":
            self._control(WIRE.CMD_STREAM_ON if params["enabled"] else WIRE.CMD_STREAM_OFF)
            if params["enabled"]:
                self._next_frame()
            else:
                self._drain()
            self._update(phase="streaming" if params["enabled"] else "paused")
        elif action == "single":
            self._control(WIRE.CMD_SINGLE_FRAME)
            self._next_frame()
        elif action == "flash":
            self._control(WIRE.CMD_FLASH_ON if params["enabled"] else WIRE.CMD_FLASH_OFF)
        elif action == "disconnect":
            if self._cleanup():
                raise TestbenchError("TB_CLEANUP_INCOMPLETE")
            self._update(phase="disconnected")
        elif action == "test":
            profile = params["profile"]
            self.verifications.update(firmware=False, mobile_contract=False)
            if profile == "smoke":
                self._smoke(params)
            elif profile == "soak":
                self._soak(params)
            else:
                from .profiles import run_profile
                run_profile(self, profile, params)

    def _cleanup(self):
        self.cleaning = True
        cleanup_errors = []
        try:
            if self.udp is not None:
                try:
                    self._udp_metrics()
                except Exception as error:
                    cleanup_errors.append(safe_error(error).code)
                for code in (WIRE.CMD_STREAM_OFF, WIRE.CMD_FLASH_OFF):
                    try:
                        self.udp.command(bytes([code]))
                    except Exception as error:
                        cleanup_errors.append(safe_error(error).code)
                try:
                    self.udp.close()
                except Exception as error:
                    cleanup_errors.append(safe_error(error).code)
                self.udp = None
            if self.client is not None:
                if self.client.rx is not None:
                    for code in (WIRE.CMD_STREAM_OFF, WIRE.CMD_FLASH_OFF):
                        try:
                            self.client.command(code)
                        except Exception as error:
                            cleanup_errors.append(safe_error(error).code)
                try:
                    self.client.disconnect()
                except Exception as error:
                    cleanup_errors.append(safe_error(error).code)
                self.client = None
            if self.uart is not None:
                try:
                    self.uart.__exit__(None, None, None)
                except Exception as error:
                    cleanup_errors.append(safe_error(error).code)
                self.uart = None
                self.uart_open_pending = False
        finally:
            if self.hardware_lock is not None:
                try:
                    self.hardware_lock.release()
                except Exception as error:
                    cleanup_errors.append(safe_error(error).code)
                else:
                    self.hardware_lock = None
            self._update(connected=False, transport=None)
            self.cleaning = False
        if cleanup_errors:
            self._event("cleanup", "failure", "TB_CLEANUP_INCOMPLETE", {"codes": cleanup_errors})
            failure = TestbenchError("TB_CLEANUP_INCOMPLETE").public()
            with self.lock:
                self.verifications.update(firmware=False, mobile_contract=False)
                if self.state["error"] is None:
                    self.state.update(phase="error", error=failure)
                    job = self.state["job"]
                    if job is not None and job["status"] == "passed":
                        job.update(status="failed", error=failure)
        if self.recovery_required:
            self._event("configuration", "recovery_required", "TB_CONFIGURATION_RECOVERY_REQUIRED")
        return cleanup_errors

    def _save_report(self):
        if self.output is None:
            return
        path = None
        try:
            self.output.mkdir(parents=True, exist_ok=True)
            # Only sanitized structured evidence is saved, never UART text or
            # request bodies. Atomic replacement avoids partially written JSON.
            destination = self.output / "results.json"
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.output,
                                             prefix=".results-", suffix=".json", delete=False) as handle:
                path = Path(handle.name)
                handle.write(json.dumps(self.report(), indent=2, allow_nan=False) + "\n")
            path.replace(destination)
        except OSError:
            self._event("report", "failure", "TB_REPORT_WRITE_FAILED")
        finally:
            if path is not None and path.exists():
                try:
                    path.unlink()
                except OSError:
                    self._event("report_cleanup", "failure", "TB_REPORT_WRITE_FAILED")
