"""Safe error surfaces; exception text is never sent to a browser or report."""

import re

ERROR_KEYS = {
    "BUSY": "tbErrorBusy",
    "CANCELLED": "tbErrorCancelled",
    "INVALID_REQUEST": "tbErrorInvalidRequest",
    "INVALID_WIFI": "tbErrorInvalidWifi",
    "SECURITY": "tbErrorSecurity",
    "NOT_CONNECTED": "tbErrorNotConnected",
    "SETUP_REQUIRED": "tbErrorSetupRequired",
    "CONFIRMATION_REQUIRED": "tbErrorConfirmationRequired",
    "RECOVERY_REQUIRED": "tbErrorRecoveryRequired",
    "UART_REQUIRED": "tbErrorUartRequired",
    "DEPENDENCY": "tbErrorDependency",
    "PLATFORM": "tbErrorPlatform",
    "HARDWARE_LOCKED": "tbErrorHardwareLocked",
    "FRAME_TIMEOUT": "tbErrorFrameTimeout",
    "HARDWARE": "tbErrorHardware",
    "INTERNAL": "tbErrorInternal",
}
SAFE_CODE = re.compile(r"(?:TB|HIL)_[A-Z0-9_]{1,100}\Z")


class TestbenchError(Exception):
    """A stable code and ARB key, without raw device or operating-system text."""

    def __init__(self, code: str, category: str = "HARDWARE", status: int = 400):
        self.code = code
        self.message_key = ERROR_KEYS[category]
        self.status = status
        super().__init__(code)

    def public(self) -> dict:
        return {"code": self.code, "message_key": self.message_key}


def safe_error(error: Exception) -> TestbenchError:
    """Preserve known harness codes, not D-Bus messages or arbitrary exceptions."""
    if isinstance(error, TestbenchError):
        return error
    if isinstance(error, ImportError):
        return TestbenchError("TB_DEPENDENCY_MISSING", "DEPENDENCY")
    if isinstance(error, (AssertionError, RuntimeError, TimeoutError)):
        code = str(error)
        if SAFE_CODE.fullmatch(code):
            category = "FRAME_TIMEOUT" if "FRAME_TIMEOUT" in code else "HARDWARE"
            return TestbenchError(code, category)
    return TestbenchError("TB_HARDWARE_OPERATION_FAILED", "HARDWARE")
