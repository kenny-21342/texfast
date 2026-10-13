#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --toolchain default swift build -c release
xcrun --toolchain default swiftc -O -I .build/release .build/release/TexFastCore.o \
  Sources/TexFast/RealtimeController.swift Sources/TexFast/RealtimeBuildCache.swift Sources/TexFast/ProblemsViewController.swift \
  Sources/TexFast/PDFPaneController.swift Sources/TexFast/SyncTeX.swift \
  Sources/TexFast/NativeLiveRenderer.swift Sources/TexFast/NativeLiveOverlay.swift \
  scripts/realtime-page-preview-smoke.swift -o .build/realtime-page-preview-smoke
STAGING=$(mktemp -d "$(pwd)/.build/page-preview-smoke.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto 'TexFast Realtime.app' "$STAGING/PagePreviewSmoke.app"
cp .build/realtime-page-preview-smoke "$STAGING/PagePreviewSmoke.app/Contents/MacOS/TexFast"
"$STAGING/PagePreviewSmoke.app/Contents/MacOS/TexFast" "$(pwd)/.build/realtime-page-preview-results.json"
