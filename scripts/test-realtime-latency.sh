#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --toolchain default swift build -c release
SOURCES=()
while IFS= read -r file; do
  if [ "$file" != 'Sources/TexFast/main.swift' ]; then SOURCES+=("$file"); fi
done < <(rg --files Sources/TexFast -g '*.swift')
xcrun --toolchain default swiftc -O -I .build/release .build/release/TexFastCore.o .build/release/SwiftTerm.o \
  "${SOURCES[@]}" scripts/realtime-latency-smoke.swift -o .build/realtime-latency-smoke
STAGING=$(mktemp -d "$(pwd)/.build/latency-smoke.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto 'TexFast Realtime.app' "$STAGING/LatencySmoke.app"
cp .build/realtime-latency-smoke "$STAGING/LatencySmoke.app/Contents/MacOS/TexFast"
"$STAGING/LatencySmoke.app/Contents/MacOS/TexFast" "$(pwd)/.build/realtime-latency-results.json"
