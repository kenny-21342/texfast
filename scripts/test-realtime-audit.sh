#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcrun --toolchain default swift build
SOURCES=()
while IFS= read -r file; do
  if [ "$file" != 'Sources/TexFast/main.swift' ]; then SOURCES+=("$file"); fi
done < <(rg --files Sources/TexFast -g '*.swift')
xcrun --toolchain default swiftc -I .build/debug .build/debug/TexFastCore.o .build/debug/SwiftTerm.o \
  "${SOURCES[@]}" scripts/realtime-audit-smoke.swift -o .build/realtime-audit-smoke
.build/realtime-audit-smoke
python3 scripts/test-realtime-shutdown.py
