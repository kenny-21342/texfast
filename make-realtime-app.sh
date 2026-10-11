#!/bin/bash
# Assemble an independent alternative app with the pinned Rust engine.
set -euo pipefail
cd "$(dirname "$0")"
./scripts/prepare-realtime-engine.sh
(cd RealtimePreview && npm ci --ignore-scripts && npm run build)
xcrun --toolchain default swift build -c release "$@"
APP="TexFast Realtime.app"
if [ -d "$APP" ]; then chmod -R u+w "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/RealtimePreview" "$APP/Contents/Resources/rtex"
cp .build/release/{TexFast,fastex} "$APP/Contents/MacOS/"
cp .build/realtime-engine/bin/rtex "$APP/Contents/MacOS/"
cp -R .build/realtime-engine/share/rtex/tex "$APP/Contents/Resources/rtex/"
cp Resources/RealtimePreview/{index.html,preview.css,preview.js} "$APP/Contents/Resources/RealtimePreview/"
cp Resources/TexFastRealtime.icns "$APP/Contents/Resources/"
cp .build/checkouts/SwiftTerm/LICENSE "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
cp .build/realtime-engine/LICENSE "$APP/Contents/Resources/realtime-tex-LICENSE.txt"
cp RealtimePreview/vendor/LICENSE "$APP/Contents/Resources/realtime-tex-vsc-plugin-LICENSE.txt"
cp RealtimePreview/node_modules/opentype.js/LICENSE "$APP/Contents/Resources/opentype-LICENSE.txt"
cp RealtimePreview/node_modules/tiny-inflate/LICENSE "$APP/Contents/Resources/tiny-inflate-LICENSE.txt"
cp RealtimePreview/node_modules/string.prototype.codepointat/LICENSE-MIT.txt "$APP/Contents/Resources/codepointat-LICENSE.txt"
cp RealtimePreview/node_modules/pdfjs-dist/LICENSE "$APP/Contents/Resources/pdfjs-LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>TexFast Realtime</string>
<key>CFBundleDisplayName</key><string>TexFast Realtime</string>
<key>CFBundleIdentifier</key><string>com.kenny-lhs.texfast.realtime</string>
<key>CFBundleExecutable</key><string>TexFast</string>
<key>CFBundleIconFile</key><string>TexFastRealtime</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.2.0</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeName</key><string>LaTeX document</string>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSItemContentTypes</key><array><string>org.tug.tex</string></array>
<key>CFBundleTypeExtensions</key><array><string>tex</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - "$APP/Contents/MacOS/rtex"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "built $(pwd)/$APP"
