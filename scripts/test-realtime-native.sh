#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --toolchain default swift build
xcrun --toolchain default swiftc -I .build/debug .build/debug/TexFastCore.o \
  Sources/TexFast/RealtimeController.swift Sources/TexFast/ProblemsViewController.swift \
  Sources/TexFast/PDFPaneController.swift Sources/TexFast/SyncTeX.swift \
  Sources/TexFast/NativeLiveRenderer.swift Sources/TexFast/NativeLiveOverlay.swift \
  scripts/realtime-native-smoke.swift -o .build/realtime-native-smoke
STAGING=$(mktemp -d "$(pwd)/.build/native-smoke.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto 'TexFast Realtime.app' "$STAGING/NativeSmoke.app"
cp .build/realtime-native-smoke "$STAGING/NativeSmoke.app/Contents/MacOS/TexFast"
"$STAGING/NativeSmoke.app/Contents/MacOS/TexFast" "$(pwd)/.build/realtime-native-preview-smoke.png"
