"""Cooperative cross-process locks shared by the dashboard and standalone HIL."""

import hashlib
import os
import stat
import sys
import tempfile
from pathlib import Path

from .errors import TestbenchError
from .settings import DEFAULT_ADAPTER


class HardwareLock:
    """Lock an adapter and optional UART; keep held until all hardware is closed.

    HIL integration: ``with HardwareLock(adapter, uart_port): ...`` before
    constructing BluezClient/UARTLog. Never unlink lock files: that would permit
    two processes to lock different inodes for the same device.
    """

    def __init__(self, adapter: str = DEFAULT_ADAPTER, uart: str | None = None,
                 directory: Path | None = None):
        self.resources = ["adapter:" + adapter]
        if uart:
            self.resources.append("uart:" + str(Path(uart).resolve()))
        self.directory = directory or Path(tempfile.gettempdir()) / f"spectrulenpor-locks-{os.getuid() if hasattr(os, 'getuid') else 'user'}"
        self.handles = []

    def acquire(self):
        if sys.platform != "linux":
            raise TestbenchError("TB_BLUEZ_REQUIRES_LINUX", "PLATFORM")
        import fcntl

        try:
            self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
            info = self.directory.lstat()
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077):
                raise TestbenchError("TB_HARDWARE_LOCK_UNSAFE", "SECURITY")
            for resource in sorted(set(self.resources)):
                name = hashlib.sha256(resource.encode()).hexdigest() + ".lock"
                descriptor = os.open(self.directory / name,
                                     os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
                handle = os.fdopen(descriptor, "r+")
                self.handles.append(handle)
                if not stat.S_ISREG(os.fstat(descriptor).st_mode):
                    raise TestbenchError("TB_HARDWARE_LOCK_UNSAFE", "SECURITY")
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            self.release()
            raise TestbenchError("TB_HARDWARE_LOCKED", "HARDWARE_LOCKED", 409) from None
        except Exception:
            self.release()
            raise
        return self

    def release(self):
        for handle in reversed(self.handles):
            handle.close()
        self.handles.clear()

    def __enter__(self):
        return self.acquire()

    def __exit__(self, *_):
        self.release()
