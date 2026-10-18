#!/bin/bash
# Bundle the verified upstream release host and its matching Lua resources.
set -euo pipefail
cd "$(dirname "$0")/.."
version=v0.0.11
revision=70453469f68ac5866dad33053d90569a4c7a162b
case "${RTEX_ARCH:-$(uname -m)}" in
  arm64|aarch64) target=aarch64-apple-darwin; expected=f4582c0c24a2defb6c3eadffcf25f3bd0b2bc118b441d1cb598dc280cba070be ;;
  x86_64) target=x86_64-apple-darwin; expected=c05efb55990676068849ed199de736a4845d99720deb13297b314ae336059454 ;;
  *) echo 'Unsupported macOS architecture' >&2; exit 1 ;;
esac
cache=".build/realtime-download"
archive="$cache/$version-rtex-$target.tar.gz"
mkdir -p "$cache"
if [ ! -f "$archive" ]; then
  curl --fail --location --retry 3 "https://github.com/kenny-21342/realtime-tex/releases/download/$version/rtex-$target.tar.gz" -o "$archive"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
[ "$actual" = "$expected" ] || { echo 'Engine release checksum mismatch' >&2; exit 1; }
# Extract into a fresh directory so files from the previous version cannot survive.
python3 - "$archive" "$revision" "$version" <<'PYCODE'
import shutil, subprocess, sys, tempfile
from pathlib import Path
engine = Path('.build/realtime-engine')
with tempfile.TemporaryDirectory(prefix='engine-release-', dir='.build') as folder:
    stage = Path(folder)
    subprocess.run(['tar', '-xzf', sys.argv[1], '-C', str(stage), '--strip-components=1'], check=True)
    (stage/'SOURCE_REVISION').write_text(sys.argv[2] + '\n')
    (stage/'RELEASE_VERSION').write_text(sys.argv[3] + '\n')
    if engine.exists(): shutil.rmtree(engine)
    shutil.copytree(stage, engine)
PYCODE
