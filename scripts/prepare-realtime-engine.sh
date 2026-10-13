#!/bin/bash
# Bundle the verified upstream release host and its matching Lua resources.
set -euo pipefail
cd "$(dirname "$0")/.."
version=v0.0.10
revision=83466a1c1293a5b1525f8bcc53c4ea95130dca5a
case "${RTEX_ARCH:-$(uname -m)}" in
  arm64|aarch64) target=aarch64-apple-darwin; expected=8a56e73f4798e27caa9d8d971b901e497cca7219a87241e488cc602c075c5e97 ;;
  x86_64) target=x86_64-apple-darwin; expected=c9c66071a0e0f7bc81898cba8697673d638031ffd86d53eeb22c99053b3cbbbf ;;
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
