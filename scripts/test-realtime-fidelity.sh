#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --toolchain default swift build -c release
xcrun --toolchain default swiftc -O -I .build/release .build/release/TexFastCore.o \
  Sources/TexFast/RealtimeController.swift Sources/TexFast/ProblemsViewController.swift \
  Sources/TexFast/PDFPaneController.swift Sources/TexFast/SyncTeX.swift \
  Sources/TexFast/NativeLiveRenderer.swift Sources/TexFast/NativeLiveOverlay.swift \
  scripts/realtime-fidelity-smoke.swift -o .build/realtime-fidelity-smoke
STAGING=$(mktemp -d "$(pwd)/.build/fidelity-smoke.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
ditto 'TexFast Realtime.app' "$STAGING/FidelitySmoke.app"
cp .build/realtime-fidelity-smoke "$STAGING/FidelitySmoke.app/Contents/MacOS/TexFast"
"$STAGING/FidelitySmoke.app/Contents/MacOS/TexFast" "$(pwd)/.build/realtime-fidelity"
