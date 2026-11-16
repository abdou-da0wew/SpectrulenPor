import contextlib
import io
import json
import os
import signal
import threading
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from testbench.__main__ import credentials_from_environment, main, parser, run_profile, serve
from testbench.errors import TestbenchError
from testbench.settings import PASSWORD_ENV, SSID_ENV
from testbench.tests.fakes import FakeLock, fake_engine


class LifecycleEngine:
    def __init__(self, calls):
        self.calls = calls
        self.stop = threading.Event()
        self.cancelled = threading.Event()
        self.error = None
        self.close_error = None
        self.submit_error = None

    def start(self):
        self.calls.append("engine.start")
        return self

    def submit(self, *_):
        self.calls.append("engine.submit")
        if self.submit_error:
            raise self.submit_error

    def close(self):
        self.calls.append("engine.close")
        if self.close_error:
            raise self.close_error

    def snapshot(self):
        self.calls.append("engine.snapshot")
        return {"busy": False, "error": self.error}

    def report(self):
        self.calls.append("engine.report")
        return {"ok": self.error is None}


class LifecycleSignals:
    def __init__(self, calls):
        self.calls = calls
        self.previous = {signal.SIGINT: object(), signal.SIGTERM: object()}
        self.handlers = dict(self.previous)

    def install(self, signum, handler):
        self.handlers[signum] = handler
        action = "restore" if handler is self.previous[signum] else "install"
        self.calls.append(f"signal.{action}.{signum.name}")


def lifecycle_args(**changes):
    values = {"profile": "smoke", "confirm_configuration": False, "duration": 1,
              "ip": None, "adapter": "hci-fixture", "uart": None, "output": None,
              "port": 0, "opencv": False}
    return SimpleNamespace(**(values | changes))


class CliTests(unittest.TestCase):
    def test_cli_has_no_password_argument(self):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            parser().parse_args(["run", "--password", "must-not-be-accepted"])

    def test_environment_credentials_are_only_returned_in_memory(self):
        with patch.dict(os.environ, {SSID_ENV: "fixture-network", PASSWORD_ENV: "fixture-password"}, clear=True):
            output = io.StringIO()
            with contextlib.redirect_stdout(output):
                credentials = credentials_from_environment()
            self.assertEqual(credentials, {"ssid": "fixture-network", "password": "fixture-password"})
            self.assertEqual(output.getvalue(), "")

    def test_masked_prompt_uses_arb_label(self):
        with patch.dict(os.environ, {SSID_ENV: "fixture-network"}, clear=True), \
                patch("testbench.__main__.localization", return_value={"tbPasswordLabel": "WiFi password"}), \
                patch("testbench.__main__.getpass.getpass", return_value="fixture-password") as prompt:
            self.assertEqual(credentials_from_environment()["password"], "fixture-password")
            prompt.assert_called_once_with("WiFi password: ")

    def test_missing_credentials_fails_without_prompt_or_hardware(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(TestbenchError) as caught:
            credentials_from_environment()
        self.assertEqual(caught.exception.code, "TB_WIFI_CREDENTIALS_REQUIRED")

    def test_invalid_run_is_clean_error_before_hardware(self):
        output = io.StringIO()
        with patch("sys.argv", ["testbench", "run", "--profile", "soak", "--duration", "0"]), \
                patch("testbench.__main__.localization", return_value={"tbErrorInvalidRequest": "Invalid request."}), \
                patch("testbench.engine.bluez_client") as hardware, contextlib.redirect_stderr(output):
            self.assertEqual(main(), 1)
            hardware.assert_not_called()
        self.assertIn("TB_INVALID_DURATION", output.getvalue())
        self.assertNotIn("Traceback", output.getvalue())

    def test_run_reports_only_after_cleanup_and_returns_cleanup_failure(self):
        closed = []

        class Engine:
            def submit(self, *_):
                return

            def snapshot(self):
                return {"busy": False}

            def close(self):
                closed.append(True)

            def report(self):
                return {"ok": not closed}

        args = SimpleNamespace(profile="smoke", confirm_configuration=False,
                               duration=1, ip=None, adapter="hci0", uart=None, output=None)
        with patch("testbench.__main__.HardwareEngine", return_value=Engine()), \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(run_profile(args), 1)
        self.assertIn('"ok": false', output.getvalue())


class CliLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.engine = LifecycleEngine(self.calls)
        self.signals = LifecycleSignals(self.calls)
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch("testbench.__main__.HardwareEngine", return_value=self.engine))
        self.stack.enter_context(patch("testbench.__main__.signal.getsignal",
                                       side_effect=self.signals.handlers.__getitem__))
        self.stack.enter_context(patch("testbench.__main__.signal.signal", side_effect=self.signals.install))
        self.output = self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))

    def assert_released(self):
        self.assertEqual(self.calls.count("engine.close"), 1)
        self.assertEqual(self.signals.handlers, self.signals.previous)
        for signum in self.signals.previous:
            self.assertLess(self.calls.index("engine.close"),
                            self.calls.index(f"signal.restore.{signum.name}"))

    def server(self, request=None, close=None):
        calls = self.calls

        class Server:
            port = 0

            def handle_request(self):
                calls.append("server.request")
                if request:
                    request()
                else:
                    self_shutdown(signal.SIGTERM, None)

            def server_close(self):
                calls.append("server.close")
                if close:
                    close()

            def shutdown(self):
                calls.append("server.shutdown")

            def serve_forever(self, **_):
                raise AssertionError("A fake thread must not serve HTTP")

        def self_shutdown(signum, frame):
            self.signals.handlers[signum](signum, frame)

        server = Server()
        self.stack.enter_context(patch("testbench.__main__.LocalServer", return_value=server))
        return server

    def test_run_success_closes_once_before_report_and_restores_both_signals(self):
        self.assertEqual(run_profile(lifecycle_args()), 0)
        self.assert_released()
        self.assertLess(self.calls.index("engine.close"), self.calls.index("engine.report"))
        self.assertIn('"ok": true', self.output.getvalue())

    def test_run_sigint_and_sigterm_cooperatively_cancel_before_teardown(self):
        def submit(_):
            for signum in (signal.SIGINT, signal.SIGTERM):
                self.engine.cancelled.clear()
                self.signals.handlers[signum](signum, None)
                self.assertTrue(self.engine.cancelled.is_set())
            self.engine.error = {"code": "TB_CANCELLED"}

        with patch.object(self.engine, "submit", side_effect=submit):
            self.assertEqual(run_profile(lifecycle_args()), 1)
        self.assert_released()

    def test_run_preserves_submit_failure_and_attempts_all_restorations(self):
        primary = TestbenchError("TB_PRIMARY_FAILURE")
        self.engine.submit_error = primary
        self.engine.close_error = RuntimeError("private cleanup failure")

        def restore(signum, handler):
            self.signals.install(signum, handler)
            if handler is self.signals.previous[signum]:
                raise RuntimeError("private restoration failure")

        with patch("testbench.__main__.signal.signal", side_effect=restore), \
                self.assertRaises(TestbenchError) as caught:
            run_profile(lifecycle_args())
        self.assertIs(caught.exception, primary)
        self.assert_released()
        self.assertNotIn("engine.report", self.calls)
        self.assertEqual(self.output.getvalue(), "")

    def test_run_signal_installation_failure_still_closes_and_restores(self):
        primary = RuntimeError("signal installation failure")

        def install(signum, handler):
            if signum == signal.SIGTERM and handler is not self.signals.previous[signum]:
                raise primary
            self.signals.install(signum, handler)

        with patch("testbench.__main__.signal.signal", side_effect=install), \
                self.assertRaises(RuntimeError) as caught:
            run_profile(lifecycle_args())
        self.assertIs(caught.exception, primary)
        self.assert_released()
        self.assertNotIn("engine.submit", self.calls)

    def test_run_cleanup_exception_cannot_print_a_passing_report(self):
        self.engine.close_error = TestbenchError("TB_CLEANUP_INCOMPLETE")
        with self.assertRaises(TestbenchError):
            run_profile(lifecycle_args())
        self.assert_released()
        self.assertNotIn("engine.report", self.calls)
        self.assertEqual(self.output.getvalue(), "")

    def test_serve_sigterm_unwinds_and_selects_state_after_cleanup(self):
        self.server()
        original = self.engine.close

        def close():
            original()
            self.engine.error = {"code": "TB_CLEANUP_INCOMPLETE"}

        with patch.object(self.engine, "close", side_effect=close):
            self.assertEqual(serve(lifecycle_args()), 1)
        self.assertTrue(self.engine.stop.is_set())
        self.assertTrue(self.engine.cancelled.is_set())
        self.assert_released()
        self.assertLess(self.calls.index("server.close"), self.calls.index("engine.close"))
        self.assertLess(self.calls.index("engine.close"), self.calls.index("engine.snapshot"))

    def test_serve_preserves_request_failure_when_server_and_engine_close_fail(self):
        primary = TestbenchError("TB_PRIMARY_FAILURE")

        def request():
            raise primary

        def close():
            raise RuntimeError("private server cleanup failure")

        self.server(request=request, close=close)
        self.engine.close_error = RuntimeError("private engine cleanup failure")
        with self.assertRaises(TestbenchError) as caught:
            serve(lifecycle_args())
        self.assertIs(caught.exception, primary)
        self.assert_released()

    def test_serve_partial_engine_start_failure_still_closes(self):
        primary = RuntimeError("worker start failure")
        with patch.object(self.engine, "start", side_effect=primary), \
                self.assertRaises(RuntimeError) as caught:
            serve(lifecycle_args())
        self.assertIs(caught.exception, primary)
        self.assertEqual(self.calls, ["engine.close"])

    def test_serve_server_construction_failure_closes_engine_and_restores(self):
        primary = RuntimeError("server start failure")
        with patch("testbench.__main__.LocalServer", side_effect=primary), \
                self.assertRaises(RuntimeError) as caught:
            serve(lifecycle_args())
        self.assertIs(caught.exception, primary)
        self.assert_released()

    def test_serve_opencv_failure_attempts_shutdown_join_and_all_closes(self):
        primary = TestbenchError("TB_VIEWER_FAILURE")
        server = self.server()
        calls = self.calls

        class Thread:
            ident = None

            def start(self):
                calls.append("server.thread.start")
                self.ident = 1

            def join(self):
                calls.append("server.thread.join")

        with patch("testbench.__main__.threading.Thread", return_value=Thread()), \
                patch("testbench.__main__.show", side_effect=primary), \
                patch.object(server, "shutdown", side_effect=RuntimeError("shutdown failure")), \
                self.assertRaises(TestbenchError) as caught:
            serve(lifecycle_args(opencv=True))
        self.assertIs(caught.exception, primary)
        self.assertIn("server.thread.join", self.calls)
        self.assertIn("server.close", self.calls)
        self.assert_released()

    def test_main_reports_cleanup_exception_without_leaking_internal_text(self):
        self.server()
        self.engine.close_error = RuntimeError("private filesystem path")
        with patch("sys.argv", ["testbench", "serve"]), \
                patch("testbench.__main__.localization", return_value={}), \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            self.assertEqual(main(), 1)
        self.assertIn("TB_HARDWARE_OPERATION_FAILED", stderr.getvalue())
        self.assertNotIn("private", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())
        self.assert_released()


class ActualAdmissionSignalTests(unittest.TestCase):
    def setUp(self):
        self.engine = fake_engine()
        self.addCleanup(self.engine.close)
        self.signals = LifecycleSignals([])
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.stack.enter_context(patch("testbench.__main__.HardwareEngine", return_value=self.engine))
        self.stack.enter_context(patch("testbench.__main__.signal.getsignal",
                                       side_effect=self.signals.handlers.__getitem__))
        self.stack.enter_context(patch("testbench.__main__.signal.signal", side_effect=self.signals.install))
        self.stack.enter_context(patch("testbench.engine.QUIET_SECONDS", 0))
        self.output = self.stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
        self.args = lifecycle_args(adapter=self.engine.adapter)

    def interrupt(self):
        self.signals.handlers[signal.SIGTERM](signal.SIGTERM, None)

    def assert_no_acquisition(self):
        self.assertEqual(self.engine.fake_clients, [])
        self.assertIsNone(self.engine.hardware_lock)
        self.assertFalse(FakeLock.held)
        self.assertEqual(self.signals.handlers, self.signals.previous)
        self.assertTrue(self.engine.stop.is_set())

    def test_signal_after_handler_install_before_actual_submit_acquires_nothing(self):
        def install(signum, handler):
            self.signals.install(signum, handler)
            if signum == signal.SIGTERM and handler is not self.signals.previous[signum]:
                handler(signum, None)

        with patch("testbench.__main__.signal.signal", side_effect=install), \
                self.assertRaises(TestbenchError) as caught:
            run_profile(self.args)
        self.assertEqual(caught.exception.code, "TB_CANCELLED")
        self.assert_no_acquisition()

    def test_signal_immediately_before_actual_admission_is_not_cleared(self):
        original = self.engine.submit

        def submit(body):
            self.interrupt()
            return original(body)

        with patch.object(self.engine, "submit", side_effect=submit), \
                self.assertRaises(TestbenchError) as caught:
            run_profile(self.args)
        self.assertIn(caught.exception.code, ("TB_CANCELLED", "TB_ENGINE_CLOSED"))
        self.assert_no_acquisition()

    def test_signal_during_actual_job_event_reset_is_persistent(self):
        interrupt = self.interrupt

        class AdmissionEvent(threading.Event):
            def clear(self):
                interrupt()
                super().clear()

        self.engine.cancelled = AdmissionEvent()
        with self.assertRaises(TestbenchError) as caught:
            run_profile(self.args)
        self.assertEqual(caught.exception.code, "TB_CANCELLED")
        self.assert_no_acquisition()

    def test_signal_after_queue_admission_finishes_cancelled_without_hardware(self):
        original = self.engine.start

        def start():
            self.interrupt()
            return original()

        with patch.object(self.engine, "start", side_effect=start):
            self.assertEqual(run_profile(self.args), 1)
        self.assert_no_acquisition()
        self.assertEqual(self.engine.snapshot()["job"]["status"], "cancelled")
        self.assertFalse(self.engine.snapshot()["busy"])
        self.assertFalse(json.loads(self.output.getvalue())["ok"])

    def test_signal_during_running_job_wait_joins_worker_and_preserves_cancelled_report(self):
        original_factory = self.engine.client_factory

        def factory(*args):
            client = original_factory(*args)
            self.interrupt()
            return client

        self.engine.client_factory = factory
        self.assertEqual(run_profile(self.args), 1)
        self.assertEqual(len(self.engine.fake_clients), 1)
        self.assertFalse(self.engine.thread.is_alive())
        self.assertFalse(FakeLock.held)
        report = json.loads(self.output.getvalue())
        self.assertEqual(report["job"]["status"], "cancelled")
        self.assertEqual(report["error"]["code"], "TB_CANCELLED")
        self.assertFalse(report["ok"])
        self.assertEqual(self.signals.handlers, self.signals.previous)

    def test_repeated_teardown_signals_cannot_interrupt_independent_cleanup(self):
        original_factory = self.engine.client_factory
        cleaned = []

        def factory(*args):
            client = original_factory(*args)
            original = client.disconnect

            def disconnect():
                self.assertTrue(self.engine.cleaning)
                self.assertTrue(FakeLock.held)
                for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGTERM):
                    self.signals.handlers[signum](signum, None)
                original()
                cleaned.append(True)

            client.disconnect = disconnect
            return client

        self.engine.client_factory = factory
        self.assertEqual(run_profile(self.args), 0)
        self.assertEqual(cleaned, [True])
        self.assertFalse(FakeLock.held)
        self.assertEqual(self.signals.handlers, self.signals.previous)
        report = json.loads(self.output.getvalue())
        self.assertTrue(report["ok"])
        self.assertIsNone(report["error"])

    def test_repeated_teardown_signals_and_failure_preserve_original_error(self):
        original_connect = self.engine._connect

        def fail(_action, _params):
            original_connect({})
            client = self.engine.fake_clients[-1]
            original_disconnect = client.disconnect

            def disconnect():
                self.interrupt()
                self.interrupt()
                original_disconnect()
                raise OSError("private teardown detail")

            client.disconnect = disconnect
            raise TestbenchError("TB_ORIGINAL_JOB_FAILURE")

        with patch.object(self.engine, "_execute", side_effect=fail):
            self.assertEqual(run_profile(self.args), 1)
        report = json.loads(self.output.getvalue())
        self.assertEqual(report["error"]["code"], "TB_ORIGINAL_JOB_FAILURE")
        self.assertTrue(any(event.get("code") == "TB_CLEANUP_INCOMPLETE" for event in report["events"]))
        self.assertFalse(FakeLock.held)
        self.assertEqual(self.signals.handlers, self.signals.previous)
        self.assertNotIn("private teardown detail", self.output.getvalue())


if __name__ == "__main__":
    unittest.main()
