#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --toolchain default swift build -c release
SOURCES=()
while IFS= read -r file; do
  if [ "$file" != 'Sources/TexFast/main.swift' ]; then SOURCES+=("$file"); fi
done < <(rg --files Sources/TexFast -g '*.swift')
xcrun --toolchain default swiftc -O -I .build/release .build/release/TexFastCore.o .build/release/SwiftTerm.o \
  "${SOURCES[@]}" scripts/realtime-startup-smoke.swift -o .build/realtime-startup-smoke
STAGING=$(mktemp -d "$(pwd)/.build/startup-smoke.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto 'TexFast Realtime.app' "$STAGING/StartupSmoke.app"
cp .build/realtime-startup-smoke "$STAGING/StartupSmoke.app/Contents/MacOS/TexFast"
"$STAGING/StartupSmoke.app/Contents/MacOS/TexFast" "$(pwd)/.build/realtime-startup-results.json" "$@"
