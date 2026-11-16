"""Private evidence and strict host compilation for the session boundary tests."""

import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


FIRMWARE_ROOT = Path(__file__).resolve().parents[1]
STRICT_FLAGS = ("-std=c11", "-Wall", "-Wextra", "-Werror", "-Wpedantic",
                "-Wconversion", "-Wshadow")
ERROR_STUB = """
#ifndef HOST_ESP_ERR_H
#define HOST_ESP_ERR_H
typedef int esp_err_t;
enum { ESP_OK, ESP_FAIL, ESP_ERR_INVALID_ARG, ESP_ERR_INVALID_STATE,
       ESP_ERR_NO_MEM, ESP_ERR_NVS_NOT_FOUND };
#endif
"""
NETIF_STUB = """
#ifndef HOST_NETIF_H
#define HOST_NETIF_H
#include <stdint.h>
#include "esp_err.h"
typedef struct { uint32_t addr; } esp_ip4_addr_t;
typedef struct { esp_ip4_addr_t ip4; } esp_ip_addr_t;
typedef struct { int unused; } esp_netif_t;
#define IPSTR "%u.%u.%u.%u"
#define IP2STR(ip) (unsigned)((ip)->addr & 255U), \\
    (unsigned)(((ip)->addr >> 8) & 255U), \\
    (unsigned)(((ip)->addr >> 16) & 255U), (unsigned)((ip)->addr >> 24)
#endif
"""


class HostSessionHarness:
    def __init__(self, owner, name, source, inputs, extra_flags=()):
        compiler = shlex.split(os.environ.get("CC", "cc"))
        if not compiler or shutil.which(compiler[0]) is None:
            raise RuntimeError("A host C compiler is required; no tools are installed")
        root = FIRMWARE_ROOT / "test-results"
        root.mkdir(mode=0o700, exist_ok=True)
        self.artifacts = Path(tempfile.mkdtemp(prefix=name + "-", dir=root))
        self.artifacts.chmod(0o700)
        temporary = tempfile.TemporaryDirectory(prefix=name + "-")
        owner.addClassCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.binary = self.work / name
        self.records = []
        self.hashes = {str(path.relative_to(FIRMWARE_ROOT)):
                       hashlib.sha256(path.read_bytes()).hexdigest() for path in inputs}
        self.write_private("harness.c", source)
        (self.work / "esp_err.h").write_text(ERROR_STUB)
        (self.work / "esp_netif.h").write_text(NETIF_STUB)
        flags = list(STRICT_FLAGS) + list(extra_flags) + shlex.split(os.environ.get("HOST_CFLAGS", ""))
        sanitizers = os.environ.get("HOST_C_SANITIZERS", "")
        if sanitizers:
            flags += ["-fsanitize=" + sanitizers, "-fno-omit-frame-pointer"]
        command = compiler + flags + ["-I", str(self.work), "-I", str(FIRMWARE_ROOT),
            "-I", str(FIRMWARE_ROOT / "components/protocol"),
            "-I", str(FIRMWARE_ROOT / "components/ble"),
            "-I", str(FIRMWARE_ROOT / "components/wifi"),
            str(self.artifacts / "harness.c"),
            str(FIRMWARE_ROOT / "components/protocol/protocol.c"), "-o", str(self.binary)]
        result = self.run("compile", command, 30)
        sys.stderr.write(f"{name} evidence: {self.artifacts}\n")
        if result.returncode:
            raise AssertionError("Actual-source host harness compilation failed:\n" +
                                 result.stdout + result.stderr)

    def write_private(self, name, content):
        path = self.artifacts / name
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(descriptor, "w") as stream:
            stream.write(content)

    def run(self, name, command, timeout=5):
        started = datetime.now(timezone.utc).isoformat()
        result = subprocess.run(command, capture_output=True, text=True,
                                errors="backslashreplace", timeout=timeout)
        self.write_private(name + ".log", result.stdout + result.stderr)
        self.records.append({"name": name, "command": command, "started_utc": started,
            "finished_utc": datetime.now(timezone.utc).isoformat(), "exit": result.returncode})
        self.write_private("manifest.json", json.dumps({"source_sha256": self.hashes,
            "runs": self.records}, indent=2) + "\n")
        return result

    def assert_case(self, test, name):
        result = self.run(name, [str(self.binary), name])
        test.assertEqual(result.returncode, 0, result.stdout + result.stderr)
