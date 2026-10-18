#!/bin/bash
# Assemble an independent alternative app with the pinned Rust engine.
set -euo pipefail
cd "$(dirname "$0")"
./scripts/prepare-realtime-engine.sh
xcrun --toolchain default swift build -c release "$@"
APP="TexFast Realtime.app"
if [ -d "$APP" ]; then chmod -R u+w "$APP"; rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/rtex"
cp .build/release/{TexFast,fastex,rtex-host} "$APP/Contents/MacOS/"
cp .build/realtime-engine/bin/rtex "$APP/Contents/MacOS/"
cp -R .build/realtime-engine/share/rtex/tex "$APP/Contents/Resources/rtex/"
cp Resources/TexFastRealtime.icns "$APP/Contents/Resources/"
cp .build/checkouts/SwiftTerm/LICENSE "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
cp .build/realtime-engine/RELEASE_VERSION "$APP/Contents/Resources/rtex/"
cp .build/realtime-engine/SOURCE_REVISION "$APP/Contents/Resources/rtex/"
cp .build/realtime-engine/LICENSE "$APP/Contents/Resources/realtime-tex-LICENSE.txt"
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
<key>CFBundleVersion</key><string>9</string>
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
codesign --force --sign - "$APP/Contents/MacOS/rtex-host"
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "built $(pwd)/$APP"
