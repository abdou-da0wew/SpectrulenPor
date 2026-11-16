"""Loopback-only stdlib HTTP API with same-origin and mutation-token checks."""

import json
import re
import secrets
import socket
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from .errors import TestbenchError, safe_error
from .settings import (DEFAULT_PORT, HTTP_TIMEOUT_SECONDS, LOCALIZATION_ROOT,
                       LOOPBACK_HOST, MAX_HTTP_CLIENTS, MAX_JSON_BYTES, MAX_JSON_DEPTH,
                       MAX_ASSET_BYTES, MAX_REQUEST_PATH_BYTES, PROFILES,
                       STATIC_FILES, TOKEN_HEADER, WEB_ROOT)

SECURITY_HEADERS = {
    "Cache-Control": "no-store",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
    "Cross-Origin-Resource-Policy": "same-origin",
    "Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; font-src 'self'; connect-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'",
    "Permissions-Policy": "camera=(), microphone=(), geolocation=()",
}


def localization(locale, root=LOCALIZATION_ROOT):
    """ARBs, not a second JavaScript dictionary, are the source of UI strings."""
    if locale not in ("en", "ar"):
        raise TestbenchError("TB_INVALID_LOCALE", "INVALID_REQUEST")
    try:
        body = json.loads((root / f"app_{locale}.arb").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise TestbenchError("TB_LOCALIZATION_UNAVAILABLE", "INTERNAL", 503) from None
    return {key: value for key, value in body.items() if key.startswith("tb") and isinstance(value, str)}


class LocalServer(ThreadingHTTPServer):
    """Bind only an IPv4 loopback socket and limit concurrent request threads."""

    daemon_threads = True
    block_on_close = True
    allow_reuse_address = False

    def __init__(self, engine, port=DEFAULT_PORT, *, web_root=WEB_ROOT,
                 localization_root=LOCALIZATION_ROOT):
        if type(port) is not int or not 0 <= port <= 65535:
            raise TestbenchError("TB_INVALID_PORT", "INVALID_REQUEST")
        self.engine, self.web_root = engine, web_root.resolve()
        self.localization_root = localization_root
        self.csrf_token = secrets.token_urlsafe(32)
        self.slots = threading.BoundedSemaphore(MAX_HTTP_CLIENTS)
        super().__init__((LOOPBACK_HOST, port), Handler)
        self.port = self.server_address[1]
        self.authorities = {f"127.0.0.1:{self.port}", f"localhost:{self.port}"}
        self.origins = {f"http://{host}" for host in self.authorities}

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(HTTP_TIMEOUT_SECONDS)
        return connection, address

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\nCache-Control: no-store\r\n\r\n")
            finally:
                self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        # BaseServer prints raw exceptions and paths. Keep the browser's public
        # error surface and terminal logs free of request bodies and secrets.
        return


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "SpectruLenPorTestbench"
    sys_version = ""

    def log_message(self, *_):
        return

    def _reply(self, status, data=b"", content_type="application/json; charset=utf-8", headers=None):
        self.send_response(status)
        for key, value in SECURITY_HEADERS.items():
            self.send_header(key, value)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        for key, value in (headers or {}).items():
            self.send_header(key, str(value))
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD" and data:
            self.wfile.write(data)

    def _json(self, status, body):
        self._reply(status, json.dumps(body, ensure_ascii=False, allow_nan=False).encode("utf-8"))

    def send_error(self, code, message=None, explain=None):
        self._json(code, {"error": TestbenchError("TB_HTTP_REQUEST_REJECTED", "INVALID_REQUEST").public()})

    def _guard(self, mutation=False):
        hosts = self.headers.get_all("Host", [])
        origins = self.headers.get_all("Origin", [])
        if (len(hosts) != 1 or hosts[0] not in self.server.authorities
                or len(origins) > 1 or origins and origins[0] not in self.server.origins
                or self.headers.get("Sec-Fetch-Site") in ("cross-site", "same-site")):
            raise TestbenchError("TB_LOCAL_ORIGIN_REQUIRED", "SECURITY", 403)
        if mutation:
            values = self.headers.get_all(TOKEN_HEADER, [])
            if len(values) != 1 or not secrets.compare_digest(values[0].encode("utf-8"), self.server.csrf_token.encode("ascii")):
                raise TestbenchError("TB_INVALID_TOKEN", "SECURITY", 403)

    def _target(self):
        if len(self.path) > MAX_REQUEST_PATH_BYTES or not self.path.startswith("/") or self.path.startswith("//"):
            raise TestbenchError("TB_INVALID_PATH", "INVALID_REQUEST")
        target = urlsplit(self.path)
        if target.scheme or target.netloc or target.fragment or "%" in target.path or "\\" in target.path:
            raise TestbenchError("TB_INVALID_PATH", "INVALID_REQUEST")
        return target

    def _run(self, function):
        try:
            self._guard(self.command == "POST")
            function(self._target())
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            self.close_connection = True
        except Exception as error:
            failure = safe_error(error)
            try:
                self._json(failure.status, {"error": failure.public()})
            except (BrokenPipeError, ConnectionResetError, socket.timeout):
                self.close_connection = True

    def do_GET(self):
        self._run(self._get)

    def do_HEAD(self):
        self._run(self._get)

    def _get(self, target):
        path = target.path
        if target.query and path not in ("/api/localization", "/api/frame.jpg"):
            raise TestbenchError("TB_INVALID_QUERY", "INVALID_REQUEST")
        if path == "/api/config":
            self._json(200, {"csrf_token": self.server.csrf_token, "port": self.server.port,
                             "adapter": self.server.engine.adapter, "uart": self.server.engine.uart_port,
                             "profiles": list(PROFILES)})
        elif path == "/api/state":
            self._json(200, self.server.engine.snapshot())
        elif path == "/api/report":
            self._reply(200, json.dumps(self.server.engine.report(), indent=2, ensure_ascii=False, allow_nan=False).encode(),
                        headers={"Content-Disposition": 'attachment; filename="results.json"'})
        elif path == "/api/frame.jpg":
            if target.query:
                query = parse_qs(target.query, keep_blank_values=True)
                if set(query) != {"sequence"} or len(query["sequence"]) != 1 or not re.fullmatch(r"[0-9]{1,20}", query["sequence"][0]):
                    raise TestbenchError("TB_INVALID_QUERY", "INVALID_REQUEST")
            frame, sequence = self.server.engine.frame()
            self._reply(200 if frame is not None else 204, frame or b"", "image/jpeg",
                        {"X-Frame-Sequence": sequence})
        elif path == "/api/localization":
            query = parse_qs(target.query, keep_blank_values=True)
            if set(query) != {"locale"} or len(query["locale"]) != 1:
                raise TestbenchError("TB_INVALID_LOCALE", "INVALID_REQUEST")
            self._json(200, localization(query["locale"][0], self.server.localization_root))
        else:
            self._static(path)

    def _static(self, path):
        entry = STATIC_FILES.get(path)
        if entry is not None:
            relative, content_type = entry
        elif re.fullmatch(r"/assets/fonts/[A-Za-z0-9_-]+\.(woff2?|ttf|otf)", path):
            relative = path.lstrip("/")
            extension = relative.rsplit(".", 1)[1]
            content_type = {"woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf"}[extension]
        else:
            self._json(404, {"error": TestbenchError("TB_NOT_FOUND", "INVALID_REQUEST").public()})
            return
        file = (self.server.web_root / relative).resolve()
        if not file.is_relative_to(self.server.web_root) or not file.is_file():
            self._json(404, {"error": TestbenchError("TB_NOT_FOUND", "INVALID_REQUEST").public()})
            return
        if file.stat().st_size > MAX_ASSET_BYTES:
            raise TestbenchError("TB_ASSET_TOO_LARGE", "INVALID_REQUEST")
        self._reply(200, file.read_bytes(), content_type)

    def do_POST(self):
        self._run(self._post)

    def _post(self, target):
        if target.path != "/api/action" or target.query:
            self._json(404, {"error": TestbenchError("TB_NOT_FOUND", "INVALID_REQUEST").public()})
            return
        lengths = self.headers.get_all("Content-Length", [])
        if (len(lengths) != 1 or not re.fullmatch(r"[0-9]{1,5}", lengths[0])
                or not 0 < int(lengths[0]) <= MAX_JSON_BYTES
                or "Transfer-Encoding" in self.headers or "Content-Encoding" in self.headers
                or self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json"):
            raise TestbenchError("TB_INVALID_JSON_BODY", "INVALID_REQUEST")
        data = self.rfile.read(int(lengths[0]))
        if len(data) != int(lengths[0]):
            raise TestbenchError("TB_INVALID_JSON_BODY", "INVALID_REQUEST")
        depth, quoted, escaped = 0, False, False
        for byte in data:
            if quoted:
                if escaped:
                    escaped = False
                elif byte == ord("\\"):
                    escaped = True
                elif byte == ord('"'):
                    quoted = False
            elif byte == ord('"'):
                quoted = True
            elif byte in (ord("["), ord("{")):
                depth += 1
                if depth > MAX_JSON_DEPTH:
                    raise TestbenchError("TB_INVALID_JSON_BODY", "INVALID_REQUEST")
            elif byte in (ord("]"), ord("}")):
                depth -= 1

        def unique_object(pairs):
            result = {}
            for key, value in pairs:
                if key in result:
                    raise ValueError("duplicate")
                result[key] = value
            return result

        def invalid_constant(_):
            raise ValueError("constant")

        try:
            body = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object, parse_constant=invalid_constant)
        except (ValueError, UnicodeError, RecursionError):
            raise TestbenchError("TB_INVALID_JSON_BODY", "INVALID_REQUEST") from None
        job_id = self.server.engine.submit(body)
        self._json(202, {"job_id": job_id})

    def do_OPTIONS(self):
        self.send_error(405)

    do_PUT = do_DELETE = do_PATCH = do_OPTIONS
