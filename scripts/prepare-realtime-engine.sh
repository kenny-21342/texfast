#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=v0.0.7
case "${RTEX_ARCH:-$(uname -m)}" in
  arm64|aarch64) target=aarch64-apple-darwin; expected=e290ef43f810609d0206bb03d29a2ca121f1e9af3603e90ef74586a9e7fa63fa ;;
  x86_64) target=x86_64-apple-darwin; expected=1d6fd7ccd531b0cbb3fd19f790ad081859d725ed2cb7de02fb95f85b894e692d ;;
  *) echo 'Unsupported macOS architecture' >&2; exit 1 ;;
esac
archive="rtex-$target.tar.gz"
cache=".build/realtime-download"
mkdir -p "$cache" .build/realtime-engine
if [ ! -f "$cache/$archive" ]; then
  curl --fail --location --retry 3 "https://github.com/kenny-21342/realtime-tex/releases/download/$version/$archive" -o "$cache/$archive"
fi
actual=$(shasum -a 256 "$cache/$archive" | cut -d ' ' -f 1)
[ "$actual" = "$expected" ] || { echo "Engine checksum mismatch: $archive" >&2; exit 1; }
tar -xzf "$cache/$archive" -C .build/realtime-engine --strip-components=1
