#!/bin/bash
# Pin both the Rust host and Lua support to the same upstream source snapshot.
set -euo pipefail
cd "$(dirname "$0")/.."
revision=273f8cce9b8e1205f8101a1b59691bd922ffb9f5
expected=7760f32134c48589042b4f7526e9630e5551d3bded7f90488b687dc0abe8a524
case "${RTEX_ARCH:-$(uname -m)}" in
  arm64|aarch64) target=aarch64-apple-darwin ;;
  x86_64) target=x86_64-apple-darwin ;;
  *) echo 'Unsupported macOS architecture' >&2; exit 1 ;;
esac
cache=".build/realtime-download"
archive="$cache/source-${revision:0:7}.tar.gz"
source=".build/realtime-source-$revision"
mkdir -p "$cache" .build/realtime-engine/bin .build/realtime-engine/share/rtex
if [ ! -f "$archive" ]; then
  curl --fail --location --retry 3 "https://codeload.github.com/kenny-21342/realtime-tex/tar.gz/$revision" -o "$archive"
fi
actual=$(shasum -a 256 "$archive" | cut -d ' ' -f 1)
[ "$actual" = "$expected" ] || { echo 'Engine source checksum mismatch' >&2; exit 1; }
if [ ! -d "$source" ]; then
  mkdir -p "$source"
  tar -xzf "$archive" -C "$source" --strip-components=1
fi
cargo build --release --locked --manifest-path "$source/Cargo.toml" --target "$target" -p rtex-cli
cp "$source/target/$target/release/rtex" .build/realtime-engine/bin/rtex
# Replace the old resources together with the host. Never mix snapshots.
python3 - "$source" "$revision" <<'PYCODE'
import shutil, sys
from pathlib import Path
source = Path(sys.argv[1]); engine = Path('.build/realtime-engine')
tex = engine/'share/rtex/tex'
if tex.exists(): shutil.rmtree(tex)
shutil.copytree(source/'tex', tex, ignore=shutil.ignore_patterns('tests', 'experiments'))
shutil.copy2(source/'LICENSE', engine/'LICENSE')
(engine/'SOURCE_REVISION').write_text(sys.argv[2] + '\n')
PYCODE
