#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ "$#" -eq 0 ]]; then
  printf 'Usage: %s <flutter-command> [arguments...]\n' "$0" >&2
  printf 'Example: %s build apk\n' "$0" >&2
  exit 2
fi

if command -v flutter >/dev/null 2>&1; then
  FLUTTER_BIN="$(command -v flutter)"
elif [[ -x "$HOME/development/flutter/bin/flutter" ]]; then
  FLUTTER_BIN="$HOME/development/flutter/bin/flutter"
else
  printf 'Flutter executable not found on PATH or in ~/development/flutter/bin\n' >&2
  exit 127
fi

APP_VERSION="$(sed -n 's/^version: \([^+]*\)+.*/\1/p' pubspec.yaml | head -n 1)"
APP_BUILD="$(sed -n 's/^version: [^+]*+\([0-9][0-9]*\).*/\1/p' pubspec.yaml | head -n 1)"
GIT_SHA="$(git rev-parse --short=7 HEAD)"
GIT_SHA_FULL="$(git rev-parse HEAD)"
GIT_BRANCH="$(git symbolic-ref --quiet --short HEAD || printf 'detached')"
BUILD_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
  GIT_DIRTY=true
else
  GIT_DIRTY=false
fi

if [[ -z "$APP_VERSION" || -z "$APP_BUILD" ]]; then
  printf 'Could not read version/build from pubspec.yaml\n' >&2
  exit 1
fi

exec "$FLUTTER_BIN" "$@" \
  --dart-define="APP_VERSION=$APP_VERSION" \
  --dart-define="APP_BUILD=$APP_BUILD" \
  --dart-define="GIT_SHA=$GIT_SHA" \
  --dart-define="GIT_SHA_FULL=$GIT_SHA_FULL" \
  --dart-define="GIT_BRANCH=$GIT_BRANCH" \
  --dart-define="GIT_DIRTY=$GIT_DIRTY" \
  --dart-define="BUILD_DATE=$BUILD_DATE"
