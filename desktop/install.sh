#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$APP_DIR"
python3 - "$ROOT/com.spectrulenpor.Lab.desktop.in" "$APP_DIR/com.spectrulenpor.Lab.desktop" "$ROOT/run.sh" <<'PY'
from pathlib import Path
import sys
template, destination, launcher = map(Path, sys.argv[1:])
content = template.read_text(encoding="utf-8")
content = content.replace("@LAUNCHER@", '"' + str(launcher) + '"')
destination.write_text(content, encoding="utf-8")
destination.chmod(0o644)
PY
chmod +x "$ROOT/run.sh"
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi
printf 'Installed SpectruLenPor Lab launcher:\n  %s\n' "$APP_DIR/com.spectrulenpor.Lab.desktop"
printf 'Launch it from GNOME Activities or run:\n  %s\n' "$ROOT/run.sh"
