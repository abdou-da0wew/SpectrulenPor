#!/usr/bin/env bash
set -euo pipefail
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_FILE="$APP_DIR/com.spectrulenpor.Lab.desktop"
rm -f "$DESKTOP_FILE"
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
fi
printf 'Removed %s\n' "$DESKTOP_FILE"
