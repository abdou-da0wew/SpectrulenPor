"""Stdlib D-Bus/GLib stubs; all BluezClient transport methods stay real."""

import contextlib
import sys
from types import ModuleType, SimpleNamespace
from unittest.mock import patch

from testbench.transport import WIRE, bluez_client

FIXTURE_SSID = "source-fix-fixture"
FIXTURE_PASSWORD = "fixture-password"
WAIT_SECONDS = 3


@contextlib.contextmanager
def actual_bluez(engine):
    """Construct the actual adapter without importing native bindings or using a bus."""
    writes = []
    pending = []
    context = SimpleNamespace(pending=lambda: bool(pending),
                              iteration=lambda _: pending.pop(0)())
    manager = SimpleNamespace(GetManagedObjects=lambda: {})
    bus = SimpleNamespace(get_object=lambda _name, path: manager if path == "/" else object())
    dbus = ModuleType("dbus")
    dbus.SystemBus = lambda: bus
    dbus.Interface = lambda value, _interface: value
    dbus.Array = lambda value, **_: bytes(value)
    dbus.Dictionary = lambda value, **_: value
    mainloop = ModuleType("dbus.mainloop")
    glib = ModuleType("dbus.mainloop.glib")
    glib.DBusGMainLoop = lambda **_: None
    gi = ModuleType("gi")
    repository = ModuleType("gi.repository")
    repository.GLib = SimpleNamespace(MainContext=SimpleNamespace(default=lambda: context))
    modules = {"dbus": dbus, "dbus.mainloop": mainloop, "dbus.mainloop.glib": glib,
               "gi": gi, "gi.repository": repository}
    with patch.dict(sys.modules, modules):
        client = bluez_client(engine.adapter, engine.cooperate, engine._publish)
        fixture = SimpleNamespace(client=client, writes=writes, pending=pending, during_write=None)

        def write_value(data, _options, **_):
            code = data[0]
            # Keep only control bytes and guard state, never credential payloads.
            writes.append({"code": code, "uncertain": engine.recovery_required})
            if fixture.during_write is not None:
                fixture.during_write(code)
            if code == WIRE.CMD_WIFI_CONFIG_PUT:
                notification = (b"$CMD:wifi_config_received\n$ESP_MAC:AA:BB:CC:DD:EE:FF\n"
                                b"$ESP_NAME:spectrulenpor-fixture\n")
                pending.append(lambda: client._notification(None, {"Value": notification}, []))

        client.rx = SimpleNamespace(WriteValue=write_value)
        client.paired = True
        engine.client = client
        try:
            yield fixture
        finally:
            engine.client = None
