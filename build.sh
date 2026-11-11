#!/bin/zsh
# Builds Courage.app and installs it to ~/Applications (set APPDIR to change; NO_INSTALL=1 to only build)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Courage.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 Sources/main.swift -o "$APP/Contents/MacOS/Courage" \
  -framework AppKit -framework SwiftUI -framework PDFKit -framework ServiceManagement

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Courage</string>
  <key>CFBundleIdentifier</key><string>io.github.alapha23.courage</string>
  <key>CFBundleExecutable</key><string>Courage</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.1.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
[[ -n "${NO_INSTALL:-}" ]] && { echo "Built $APP"; exit 0; }
APPDIR="${APPDIR:-$HOME/Applications}"
mkdir -p "$APPDIR"
rm -rf "$APPDIR/Courage.app"
cp -R "$APP" "$APPDIR/"
echo "Installed $APPDIR/Courage.app"
