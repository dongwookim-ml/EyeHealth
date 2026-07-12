#!/bin/bash
# Builds EyeHealth and packages it into a runnable .app bundle under dist/.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="EyeHealth"
BUNDLE_ID="com.dongwookim.eyehealth"
CONFIG="release"

echo "==> Building ($CONFIG)…"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/$APP_NAME"
APP="dist/$APP_NAME.app"

echo "==> Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 Dongwoo Kim</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Code signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "==> Done: $APP"
echo "    Run it with:  open \"$APP\""
