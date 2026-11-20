#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHROME_BIN="${CHROME_BIN:-}"

if [[ -z "$CHROME_BIN" ]]; then
  for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$candidate" >/dev/null 2>&1; then
      CHROME_BIN="$(command -v "$candidate")"
      break
    fi
  done
fi

if [[ -z "$CHROME_BIN" || ! -x "$CHROME_BIN" ]]; then
  printf 'Chromium/Google Chrome was not found. Set CHROME_BIN to its executable path.\n' >&2
  exit 1
fi

render() {
  local source="$1"
  local output="$2"
  local source_path="$ROOT/$source"
  local output_path="$ROOT/$output"

  if [[ ! -f "$source_path" ]]; then
    printf 'Missing diagram source: %s\n' "$source_path" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$output_path")"
  printf 'Rendering %s -> %s\n' "$source" "$output"
  "$CHROME_BIN" \
    --headless=new \
    --disable-gpu \
    --no-sandbox \
    --disable-dev-shm-usage \
    --hide-scrollbars \
    --force-device-scale-factor=1 \
    --window-size=1600,1000 \
    --virtual-time-budget=3000 \
    --screenshot="$output_path" \
    "file://$source_path" >/dev/null 2>&1

  if [[ ! -s "$output_path" ]]; then
    printf 'Chrome did not produce %s\n' "$output_path" >&2
    exit 1
  fi
}

render "docs/diagrams/architecture.html" "docs/assets/architecture.png"
render "docs/diagrams/pipeline.html" "docs/diagrams/pipeline.png"
render "docs/diagrams/scientific-rag.html" "docs/assets/scientific-rag.png"

printf '\nRendered diagram assets:\n'
file "$ROOT/docs/assets/architecture.png" "$ROOT/docs/diagrams/pipeline.png" "$ROOT/docs/assets/scientific-rag.png"
