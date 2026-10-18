#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --toolchain default swift build
xcrun --toolchain default swiftc -parse-as-library -I .build/debug .build/debug/TexFastCore.o \
  scripts/engine-update-smoke.swift -o .build/engine-update-smoke
.build/engine-update-smoke
xcrun --toolchain default swiftc -parse-as-library -I .build/debug .build/debug/TexFastCore.o \
  Sources/TexFast/EngineUpdateWindowController.swift scripts/engine-update-ui-smoke.swift -o .build/engine-update-ui-smoke
STAGING=$(mktemp -d "$(pwd)/.build/engine-update-ui.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto 'TexFast Realtime.app' "$STAGING/UpdateSmoke.app"
cp .build/engine-update-ui-smoke "$STAGING/UpdateSmoke.app/Contents/MacOS/TexFast"
"$STAGING/UpdateSmoke.app/Contents/MacOS/TexFast"
