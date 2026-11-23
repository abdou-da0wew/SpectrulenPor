#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANDROID="$ROOT/android"
MODE=build
if [[ "$#" -gt 0 ]]; then MODE="$1"; fi

cd "$ANDROID"
./gradlew --no-daemon --max-workers=2 \
  :app:assembleBenchmark \
  :macrobenchmark:assembleBenchmark

printf '\nBenchmark target APK:\n'
find app/build/outputs/apk/benchmark -maxdepth 1 -type f -name '*.apk' -printf '%p (%s bytes)\n' 2>/dev/null || true
printf '\nMacrobenchmark instrumentation APK:\n'
find macrobenchmark/build/outputs/apk/benchmark -maxdepth 1 -type f -name '*.apk' -printf '%p (%s bytes)\n' 2>/dev/null || true

if [[ "$MODE" == "run" ]]; then
  adb devices
  ./gradlew --no-daemon --max-workers=2 :macrobenchmark:connectedBenchmarkAndroidTest
elif [[ "$MODE" != "build" ]]; then
  echo "Usage: $0 [build|run]" >&2
  exit 2
fi
