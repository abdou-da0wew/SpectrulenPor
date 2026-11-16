"""Load the checkout's existing HIL clients without relying on the working directory."""

import importlib
import sys

from .settings import HIL_ROOT


def helpers():
    """Return the shared wire contract; external dependencies are loaded on connect."""
    path = str(HIL_ROOT)
    if path not in sys.path:
        sys.path.insert(0, path)
    return importlib.import_module("hardware_helpers")


def suites():
    """Return the real hardware suite and missing-AP evidence routines."""
    helpers()
    return importlib.import_module("hardware_e2e"), importlib.import_module("wifi_retry_hil")
