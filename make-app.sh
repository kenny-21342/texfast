#!/bin/bash
# Assemble TexFast.app from the SwiftPM build product.
set -e
cd "$(dirname "$0")"
xcrun --toolchain default swift build -c release "$@"
APP="TexFast.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/TexFast "$APP/Contents/MacOS/TexFast"
cp .build/release/fastex "$APP/Contents/MacOS/fastex"
cp Resources/TexFast.icns "$APP/Contents/Resources/TexFast.icns"
cp .build/checkouts/SwiftTerm/LICENSE "$APP/Contents/Resources/SwiftTerm-LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>TexFast</string>
  <key>CFBundleDisplayName</key><string>TexFast</string>
  <key>CFBundleIdentifier</key><string>com.kenny-lhs.texfast</string>
  <key>CFBundleExecutable</key><string>TexFast</string>
  <key>CFBundleIconFile</key><string>TexFast</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>LaTeX document</string>
    <key>CFBundleTypeRole</key><string>Editor</string>
    <key>LSItemContentTypes</key><array><string>org.tug.tex</string></array>
    <key>CFBundleTypeExtensions</key><array><string>tex</string></array>
  </dict></array>
</dict>
</plist>
PLIST
codesign --force --deep --sign - "$APP" 2>/dev/null || true
echo "built $(pwd)/$APP"
