"""Cooperative signals for standalone HIL, without asynchronous cleanup exceptions."""

import signal
import subprocess
import sys
import threading
import time
from contextlib import contextmanager
from types import SimpleNamespace

from hardware_helpers import POLL_SECONDS

UDP_FRAME_TIMEOUT_SECONDS = 10


class StandaloneInterrupted(RuntimeError):
    """Keep cancellation distinguishable from transport and teardown failures."""

    def __init__(self, code):
        self.code = code
        super().__init__(code)


class StandaloneSignals:
    def __init__(self, code="HIL_INTERRUPTED"):
        self.code = code
        self.signum = None
        self.previous = {}
        self.cleaning = False
        self.protected = 0
        self.cleanup_errors = []

    def request(self, signum, _frame=None):
        # No locks, I/O or exceptions in the handler, including repeated signals.
        if self.signum is None:
            self.signum = signum

    def checkpoint(self):
        if self.signum is not None and not self.cleaning and not self.protected:
            raise StandaloneInterrupted(self.code)

    def begin_cleanup(self):
        self.cleaning = True

    @contextmanager
    def cleanup(self):
        """Shield local finally blocks without disabling later suite checkpoints."""
        self.protected += 1
        try:
            yield
        finally:
            self.protected -= 1

    def __enter__(self):
        # Python only permits handler installation on the main interpreter thread.
        if threading.current_thread() is not threading.main_thread():
            return self
        try:
            for name in ("SIGINT", "SIGTERM"):
                signum = getattr(signal, name, None)
                if signum is not None:
                    self.previous[signum] = signal.getsignal(signum)
                    signal.signal(signum, self.request)
        except BaseException:
            self.__exit__(*sys.exc_info())
            raise
        return self

    def __exit__(self, exc_type, *_):
        self.begin_cleanup()
        for signum, handler in self.previous.items():
            try:
                signal.signal(signum, handler)
            except BaseException as error:
                self.cleanup_errors.append(type(error).__name__)
        if self.cleanup_errors and exc_type is None:
            raise RuntimeError("HIL_CLEANUP_INCOMPLETE") from None

    @contextmanager
    def owned(self, resource):
        """Enter fully before checking cancellation, then shield release under ownership."""
        try:
            value = resource.__enter__()
        except BaseException:
            self.begin_cleanup()
            raise
        failure = None
        try:
            yield value
        except BaseException as error:
            failure = error
            raise
        finally:
            self.begin_cleanup()
            try:
                resource.__exit__(type(failure) if failure else None, failure,
                                  failure.__traceback__ if failure else None)
            except BaseException as error:
                # UARTLog already retains its safe teardown details on the resource.
                if not getattr(resource, "cleanup_errors", ()):
                    self.cleanup_errors.append(type(error).__name__)
                if failure is None:
                    raise

    def final_failure(self, failure):
        """Select only after teardown; a later signal must not erase the original error."""
        if failure is not None:
            return failure
        if self.signum is not None:
            return StandaloneInterrupted(self.code)
        if self.cleanup_errors:
            return RuntimeError("HIL_CLEANUP_INCOMPLETE")
        return None

    def bind_client(self, client):
        """Slice long pump delays; existing reply waits call this same client pump."""
        original = getattr(client, "pump", None)
        if original is not None:
            def pump(seconds=0.0):
                deadline = time.monotonic() + seconds
                while True:
                    self.checkpoint()
                    original()
                    self.checkpoint()
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        return
                    time.sleep(min(POLL_SECONDS, remaining))
            client.pump = pump
        original_write = getattr(client, "write", None)
        if original_write is not None:
            def write(*args, **kwargs):
                self.checkpoint()
                result = original_write(*args, **kwargs)
                self.checkpoint()
                return result
            client.write = write

    def command_output(self, command, timeout):
        """Poll a read-only credential query and reap our child before releasing the lease."""
        self.checkpoint()
        process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True)
        try:
            deadline = time.monotonic() + timeout
            while True:
                self.checkpoint()
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("HIL_WIFI_PROFILE_TIMEOUT")
                try:
                    output, _ = process.communicate(timeout=min(POLL_SECONDS, remaining))
                except subprocess.TimeoutExpired:
                    continue
                self.checkpoint()
                if process.returncode != 0:
                    raise RuntimeError("HIL_WIFI_PROFILE_UNAVAILABLE")
                return output
        finally:
            failure = sys.exc_info()[1]
            errors = []
            with self.cleanup():
                running = True
                try:
                    running = process.poll() is None
                except BaseException as error:
                    errors.append(type(error).__name__)
                if running:
                    for operation in (process.kill, process.communicate):
                        try:
                            operation()
                        except BaseException as error:
                            errors.append(type(error).__name__)
                for pipe in (process.stdout, process.stderr):
                    if pipe is not None:
                        try:
                            pipe.close()
                        except BaseException as error:
                            errors.append(type(error).__name__)
            self.cleanup_errors.extend(errors)
            if errors and failure is None:
                raise RuntimeError("HIL_CLEANUP_INCOMPLETE") from None

    def bind_uart(self, uart):
        original = getattr(uart, "wait_for", None)
        if original is not None:
            def wait_for(predicate, since, *args, **kwargs):
                def checked(text):
                    self.checkpoint()
                    result = predicate(text)
                    self.checkpoint()
                    return result
                self.checkpoint()
                result = original(checked, since, *args, **kwargs)
                self.checkpoint()
                return result
            uart.wait_for = wait_for
        original_reset = uart.reset

        def reset(*args, **kwargs):
            self.checkpoint()
            result = original_reset(*args, **kwargs)
            self.checkpoint()
            return result
        uart.reset = reset

    def bind_udp(self, receiver):
        original = receiver.next_frame

        def next_frame(client=None, timeout=UDP_FRAME_TIMEOUT_SECONDS):
            def pump():
                self.checkpoint()
                if client is not None:
                    client.pump()
            self.checkpoint()
            result = original(SimpleNamespace(pump=pump), timeout)
            self.checkpoint()
            return result
        receiver.next_frame = next_frame
        return receiver
