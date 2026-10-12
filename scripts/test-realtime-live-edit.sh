#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --toolchain default swift build -c release
SOURCES=()
while IFS= read -r file; do
  if [ "$file" != 'Sources/TexFast/main.swift' ]; then SOURCES+=("$file"); fi
done < <(rg --files Sources/TexFast -g '*.swift')
xcrun --toolchain default swiftc -O -I .build/release .build/release/TexFastCore.o .build/release/SwiftTerm.o \
  "${SOURCES[@]}" scripts/realtime-live-edit-smoke.swift -o .build/realtime-live-edit-smoke
STAGING=$(mktemp -d "$(pwd)/.build/live-edit-smoke.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto 'TexFast Realtime.app' "$STAGING/LiveEditSmoke.app"
cp .build/realtime-live-edit-smoke "$STAGING/LiveEditSmoke.app/Contents/MacOS/TexFast"
"$STAGING/LiveEditSmoke.app/Contents/MacOS/TexFast" "${LIVE_EDIT_REPORT:-$(pwd)/.build/realtime-live-edit-results.json}" "$@"
