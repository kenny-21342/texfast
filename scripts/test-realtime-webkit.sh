#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --toolchain default swift build
xcrun --toolchain default swiftc -I .build/debug .build/debug/TexFastCore.o \
  Sources/TexFast/RealtimeController.swift Sources/TexFast/RealtimePreviewController.swift \
  Sources/TexFast/ProblemsViewController.swift Sources/TexFast/PDFPaneController.swift \
  Sources/TexFast/SyncTeX.swift scripts/realtime-webkit-smoke.swift \
  -o .build/realtime-webkit-smoke
ditto 'TexFast Realtime.app' .build/RealtimeSmoke.app
cp .build/realtime-webkit-smoke .build/RealtimeSmoke.app/Contents/MacOS/TexFast
.build/RealtimeSmoke.app/Contents/MacOS/TexFast "$(pwd)/.build/realtime-preview-smoke.png"
