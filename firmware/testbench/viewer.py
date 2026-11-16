"""OpenCV displays the engine store or local HTTP; it never owns a UDP socket."""

import json
import os
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener

from .errors import TestbenchError
from .settings import (HTTP_TIMEOUT_SECONDS, MAX_HTTP_FRAME_BYTES, MAX_JSON_BYTES,
                       VIEW_POLL_SECONDS, VIEW_TITLE)


def local_endpoint(url):
    """Canonicalize localhost to an IP; reject credentials, paths and redirects."""
    try:
        target = urlsplit(url)
        port = target.port
    except (ValueError, TypeError):
        raise TestbenchError("TB_INVALID_BACKEND_URL", "INVALID_REQUEST") from None
    if (target.scheme != "http" or target.hostname not in ("127.0.0.1", "localhost")
            or port is None or not 1 <= port <= 65535 or target.username is not None
            or target.password is not None or target.path not in ("", "/") or target.query or target.fragment):
        raise TestbenchError("TB_INVALID_BACKEND_URL", "INVALID_REQUEST")
    return f"http://127.0.0.1:{port}"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_):
        return None


class HttpFrameSource:
    """An existing dashboard is the hardware owner; this is only a frame consumer."""

    def __init__(self, url):
        self.url = local_endpoint(url)
        self.opener = build_opener(ProxyHandler({}), NoRedirect())
        self.sequence = None

    def _get(self, path, limit):
        try:
            with self.opener.open(Request(self.url + path), timeout=HTTP_TIMEOUT_SECONDS) as response:
                data = response.read(limit + 1)
                if len(data) > limit:
                    raise TestbenchError("TB_HTTP_RESPONSE_TOO_LARGE", "INVALID_REQUEST")
                return response.status, response.headers, data
        except (HTTPError, URLError, OSError):
            raise TestbenchError("TB_BACKEND_UNAVAILABLE", "HARDWARE") from None

    def read(self):
        status, headers, data = self._get("/api/frame.jpg", MAX_HTTP_FRAME_BYTES)
        if status == 204:
            return None
        if status != 200 or headers.get_content_type() != "image/jpeg":
            raise TestbenchError("TB_INVALID_HTTP_FRAME")
        sequence = headers.get("X-Frame-Sequence")
        if sequence is not None and sequence == self.sequence:
            return None
        self.sequence = sequence
        return data

    def state(self):
        _, _, data = self._get("/api/state", MAX_JSON_BYTES * 32)
        try:
            return json.loads(data)
        except (ValueError, UnicodeError):
            raise TestbenchError("TB_INVALID_HTTP_STATE") from None


class EngineFrameSource:
    def __init__(self, engine):
        self.engine, self.sequence = engine, None

    def read(self):
        frame, sequence = self.engine.frame()
        if frame is None or sequence == self.sequence:
            return None
        self.sequence = sequence
        return frame


def show(source, stop=None):
    """Run OpenCV's GUI on the main thread, with no untranslated text overlays."""
    if sys.platform == "linux" and not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")):
        raise TestbenchError("TB_OPENCV_GUI_UNAVAILABLE", "DEPENDENCY")
    try:
        import cv2
        import numpy as np
    except ImportError:
        raise TestbenchError("TB_OPENCV_MISSING", "DEPENDENCY") from None
    if not hasattr(cv2, "namedWindow"):
        raise TestbenchError("TB_OPENCV_GUI_UNAVAILABLE", "DEPENDENCY")
    window_created = False
    try:
        while stop is None or not stop.is_set():
            data = source.read()
            if data is not None:
                image = cv2.imdecode(np.frombuffer(data, dtype=np.uint8), cv2.IMREAD_COLOR)
                if image is None:
                    raise TestbenchError("TB_INVALID_JPEG")
                if not window_created:
                    cv2.namedWindow(VIEW_TITLE, cv2.WINDOW_NORMAL)
                    window_created = True
                cv2.imshow(VIEW_TITLE, image)
            if window_created:
                if cv2.waitKey(1) & 0xFF in (27, ord("q")):
                    return
                if cv2.getWindowProperty(VIEW_TITLE, cv2.WND_PROP_VISIBLE) < 1:
                    return
            time.sleep(VIEW_POLL_SECONDS)
    except cv2.error:
        raise TestbenchError("TB_OPENCV_GUI_UNAVAILABLE", "DEPENDENCY") from None
    finally:
        if window_created:
            cv2.destroyAllWindows()
