import http.client
import json
import socket
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

from testbench.backend import LocalServer
from testbench.errors import TestbenchError
from testbench.settings import MAX_JSON_BYTES, TOKEN_HEADER
from testbench.tests.fakes import FAKE_JPEG, fake_engine
from testbench.viewer import EngineFrameSource, HttpFrameSource, local_endpoint


class BackendTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.web = self.root / "web"
        self.web.mkdir()
        (self.web / "index.html").write_text("<!doctype html><title>Test</title>")
        (self.web / "app.js").write_text("'use strict';")
        self.arb = self.root / "l10n"
        self.arb.mkdir()
        for locale in ("en", "ar"):
            (self.arb / f"app_{locale}.arb").write_text(json.dumps({"@@locale": locale, "tbTitle": locale,
                                                                  "otherKey": "private", "@tbTitle": {}}))
        self.engine = fake_engine()
        self.server = LocalServer(self.engine, 0, web_root=self.web, localization_root=self.arb)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01})
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.engine.close()
        self.directory.cleanup()

    def request(self, method, path, body=None, headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.port, timeout=2)
        try:
            connection.request(method, path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            connection.close()

    def mutation_headers(self):
        return {TOKEN_HEADER: self.server.csrf_token, "Content-Type": "application/json"}

    def test_loopback_only_config_and_security_headers(self):
        self.assertEqual(self.server.server_address[0], "127.0.0.1")
        status, headers, data = self.request("GET", "/api/config")
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(data)["csrf_token"], self.server.csrf_token)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertIn("frame-ancestors 'none'", headers["Content-Security-Policy"])
        self.assertNotIn("Access-Control-Allow-Origin", headers)

    def test_dns_rebinding_host_rejected_on_reads(self):
        for host in ("evil.invalid", "127.0.0.1", f"evil.invalid:{self.server.port}", f"localhost:{self.server.port + 1}"):
            status, _, data = self.request("GET", "/api/config", headers={"Host": host})
            self.assertEqual(status, 403)
            self.assertEqual(json.loads(data)["error"]["code"], "TB_LOCAL_ORIGIN_REQUIRED")

    def test_cross_origin_null_and_fetch_metadata_rejected(self):
        for headers in ({"Origin": "http://evil.invalid"}, {"Origin": "null"}, {"Sec-Fetch-Site": "cross-site"}):
            self.assertEqual(self.request("GET", "/api/state", headers=headers)[0], 403)
        self.assertEqual(self.request("GET", "/api/state", headers={"Origin": f"http://localhost:{self.server.port}"})[0], 200)

    def test_token_required_for_every_mutation(self):
        body = json.dumps({"action": "connect"})
        for token in (None, "wrong"):
            headers = {"Content-Type": "application/json"}
            if token:
                headers[TOKEN_HEADER] = token
            self.assertEqual(self.request("POST", "/api/action", body, headers)[0], 403)
        self.assertFalse(self.engine.fake_clients)

    def test_good_action_is_accepted_with_job_id(self):
        status, _, data = self.request("POST", "/api/action", json.dumps({"action": "connect"}), self.mutation_headers())
        self.assertEqual(status, 202)
        self.assertIn("job_id", json.loads(data))

    def test_json_size_content_type_duplicates_nan_and_depth(self):
        cases = (("{}", {"Content-Type": "text/plain"}),
                 ("x" * (MAX_JSON_BYTES + 1), {}),
                 ('{"action":"connect","action":"disconnect"}', {}),
                 ('{"action":"test","params":{"profile":"soak","duration":NaN}}', {}),
                 ("[" * 1500 + "]" * 1500, {}), ("not json", {}))
        for body, override in cases:
            with self.subTest(body=body[:50]):
                headers = self.mutation_headers()
                headers.update(override)
                status, _, data = self.request("POST", "/api/action", body, headers)
                self.assertEqual(status, 400)
                self.assertEqual(json.loads(data)["error"]["code"], "TB_INVALID_JSON_BODY")

    def test_mutations_unknown_paths_are_not_dispatched(self):
        self.assertEqual(self.request("POST", "/api/erase", "{}", self.mutation_headers())[0], 404)
        self.assertEqual(self.request("DELETE", "/api/action", "{}", self.mutation_headers())[0], 405)

    def test_localization_only_authoritative_tb_keys(self):
        for locale in ("en", "ar"):
            status, _, data = self.request("GET", f"/api/localization?locale={locale}")
            self.assertEqual(status, 200)
            self.assertEqual(json.loads(data), {"tbTitle": locale})
        for query in ("locale=fr", "locale=en&locale=ar", "locale=en&file=/etc/passwd", ""):
            self.assertEqual(self.request("GET", "/api/localization?" + query)[0], 400)

    def test_path_whitelist_and_symlink_escape(self):
        outside = self.root / "outside"
        outside.write_text("must never serve")
        (self.web / "styles.css").symlink_to(outside)
        self.assertEqual(self.request("GET", "/")[0], 200)
        self.assertEqual(self.request("GET", "/app.js")[0], 200)
        for path in ("/styles.css", "/../../outside", "/etc/passwd", "/hardware.py", "/assets/fonts/../../outside"):
            self.assertEqual(self.request("GET", path)[0], 404)
        self.assertEqual(self.request("GET", "/%2e%2e/outside")[0], 400)

    def test_no_frame_204_and_same_engine_jpeg_for_all_consumers(self):
        self.assertEqual(self.request("GET", "/api/frame.jpg")[0], 204)
        with self.engine.lock:
            self.engine.latest = FAKE_JPEG
            self.engine.state["frame"]["sequence"] = 4
        self.assertEqual(self.request("GET", "/api/frame.jpg")[2], FAKE_JPEG)
        self.assertEqual(self.request("GET", "/api/frame.jpg?sequence=4")[2], FAKE_JPEG)
        self.assertEqual(self.request("GET", "/api/frame.jpg?file=/etc/passwd")[0], 400)
        self.assertEqual(EngineFrameSource(self.engine).read(), FAKE_JPEG)
        source = HttpFrameSource(f"http://localhost:{self.server.port}")
        original = socket.socket
        created = []

        def track(*args, **kwargs):
            sock = original(*args, **kwargs)
            created.append(sock.type)
            return sock

        with patch("socket.socket", side_effect=track):
            self.assertEqual(source.read(), FAKE_JPEG)
            self.assertIsNone(source.read())
            self.assertEqual(source.state()["frame"]["sequence"], 4)
        self.assertNotIn(socket.SOCK_DGRAM, created)
        self.assertFalse(self.engine.fake_clients)

    def test_head_does_not_send_body(self):
        status, headers, body = self.request("HEAD", "/api/state")
        self.assertEqual(status, 200)
        self.assertGreater(int(headers["Content-Length"]), 0)
        self.assertEqual(body, b"")

    def test_viewer_rejects_remote_urls_credentials_and_paths(self):
        for url in ("https://localhost:8765", "http://evil.invalid:8765", "http://127.0.0.1:8765/private",
                    "http://user:password@localhost:8765", "http://localhost", "http://localhost:0",
                    "http://localhost:8765#fragment", "http://localhost:8765?secret"):
            with self.subTest(url=url), self.assertRaises(TestbenchError):
                local_endpoint(url)


if __name__ == "__main__":
    unittest.main()
