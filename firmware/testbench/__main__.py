#!/usr/bin/env python3
"""Serve the local dashboard, run a hardware profile, or consume its HTTP frames."""

import argparse
import getpass
import json
import os
import signal
import sys
import threading
from pathlib import Path

from .backend import LocalServer, localization
from .engine import HardwareEngine
from .errors import TestbenchError, safe_error
from .settings import (DEFAULT_ADAPTER, DEFAULT_PORT, DEFAULT_SOAK_SECONDS,
                       HTTP_POLL_SECONDS, PASSWORD_ENV, PROFILES, SSID_ENV,
                       WORKER_POLL_SECONDS)
from .viewer import EngineFrameSource, HttpFrameSource, show


def parser():
    arguments = argparse.ArgumentParser(description=__doc__)
    commands = arguments.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="Serve the loopback-only dashboard")
    run = commands.add_parser("run", help="Run an actual Linux hardware profile")
    view = commands.add_parser("view", help="View frames from an existing local backend, never UDP")
    for command in (serve, run):
        command.add_argument("--adapter", default=DEFAULT_ADAPTER)
        command.add_argument("--uart", help="UART device for fresh boot/reset evidence")
        command.add_argument("--output", type=Path, help="Sanitized JSON and HIL JPEG evidence directory")
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    serve.add_argument("--opencv", action="store_true", help="Display the shared frame store with OpenCV")
    run.add_argument("--profile", choices=PROFILES, default="smoke")
    run.add_argument("--wifi-from-nm", action="store_true", help="Use active NetworkManager WiFi credentials in memory")
    run.add_argument("--confirm-configuration", action="store_true", help="Consent to isolated full/missing-AP configuration tests")
    run.add_argument("--duration", type=float, default=DEFAULT_SOAK_SECONDS)
    run.add_argument("--ip", help="Manually observed ESP IPv4 address; no mDNS resolution")
    view.add_argument("--url", default=f"http://127.0.0.1:{DEFAULT_PORT}")
    return arguments


def credentials_from_environment():
    """Passwords are never command-line arguments, prints, or report fields."""
    ssid = os.environ.get(SSID_ENV)
    if not ssid:
        raise TestbenchError("TB_WIFI_CREDENTIALS_REQUIRED", "INVALID_WIFI")
    password = os.environ.get(PASSWORD_ENV)
    if password is None:
        dictionary = localization("en")
        if "tbPasswordLabel" not in dictionary:
            raise TestbenchError("TB_LOCALIZATION_KEY_MISSING", "INTERNAL")
        password = getpass.getpass(dictionary["tbPasswordLabel"] + ": ")
    return {"ssid": ssid, "password": password}


def run_profile(args):
    params = {"profile": args.profile, "confirm_configuration": args.confirm_configuration,
              "duration": args.duration}
    if args.ip:
        params["ip"] = args.ip
    if args.profile in ("full", "mobile-flow"):
        params.update({"wifi_from_nm": True} if args.wifi_from_nm else credentials_from_environment())
    engine = HardwareEngine(args.adapter, args.uart, args.output)
    previous = {}
    failure = None
    shutdown_requested = threading.Event()

    def cancel(*_):
        shutdown_requested.set()
        engine.stop.set()
        engine.cancelled.set()

    try:
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.getsignal(signum)
            signal.signal(signum, cancel)
        if shutdown_requested.is_set():
            raise TestbenchError("TB_CANCELLED", "CANCELLED")
        engine.submit({"action": "test", "params": params})
        while engine.snapshot()["busy"] and not shutdown_requested.is_set():
            engine.stop.wait(WORKER_POLL_SECONDS)
    except BaseException as error:
        failure = error
    finally:
        try:
            engine.close()
        except BaseException as error:
            failure = failure or error
        for signum, handler in previous.items():
            try:
                signal.signal(signum, handler)
            except BaseException as error:
                failure = failure or error
    if failure is not None:
        raise failure
    # Select the report only after the worker has released hardware ownership.
    report = engine.report()
    print(json.dumps(report, indent=2, ensure_ascii=False))
    return 0 if report["ok"] else 1


def serve(args):
    engine = HardwareEngine(args.adapter, args.uart, args.output)
    server = None
    server_thread = None
    stopped = threading.Event()
    previous = {}
    failure = None

    def shutdown(*_):
        stopped.set()
        engine.stop.set()
        engine.cancelled.set()

    try:
        engine.start()
        for signum in (signal.SIGINT, signal.SIGTERM):
            previous[signum] = signal.getsignal(signum)
            signal.signal(signum, shutdown)
        server = LocalServer(engine, args.port)
        print(json.dumps({"url": f"http://127.0.0.1:{server.port}", "adapter": args.adapter,
                          "uart": bool(args.uart)}), flush=True)
        if args.opencv:
            server_thread = threading.Thread(target=server.serve_forever,
                                             kwargs={"poll_interval": HTTP_POLL_SECONDS}, daemon=True)
            server_thread.start()
            show(EngineFrameSource(engine), stopped)
        else:
            server.timeout = HTTP_POLL_SECONDS
            while not stopped.is_set():
                server.handle_request()
    except BaseException as error:
        failure = error
    finally:
        stopped.set()
        cleanup = []
        if server_thread is not None and server_thread.ident is not None:
            cleanup.extend((server.shutdown, server_thread.join))
        if server is not None:
            cleanup.append(server.server_close)
        cleanup.append(engine.close)
        for close in cleanup:
            try:
                close()
            except BaseException as error:
                failure = failure or error
        for signum, handler in previous.items():
            try:
                signal.signal(signum, handler)
            except BaseException as error:
                failure = failure or error
    if failure is not None:
        raise failure
    return 1 if engine.snapshot()["error"] is not None else 0


def main():
    args = parser().parse_args()
    try:
        if args.command == "serve":
            return serve(args)
        if args.command == "run":
            return run_profile(args)
        show(HttpFrameSource(args.url))
        return 0
    except KeyboardInterrupt:
        return 130
    except Exception as error:
        failure = safe_error(error)
        try:
            message = localization("en").get(failure.message_key)
        except TestbenchError:
            message = None
        print(f"Error: {failure.code}" + (f": {message}" if message else ""), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
