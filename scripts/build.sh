#!/bin/bash
# Builds Murmrflow.app into ./build and (optionally) installs it to /Applications.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Murmrflow"

APP="$ROOT/build/Murmrflow.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/Murmrflow"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Murmrflow</string>
  <key>CFBundleDisplayName</key><string>Murmrflow</string>
  <key>CFBundleIdentifier</key><string>com.vedpatel.murmrflow</string>
  <key>CFBundleExecutable</key><string>Murmrflow</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Murmrflow records your voice to transcribe it locally.</string>
  <key>MurmrflowRoot</key><string>$ROOT</string>
</dict>
</plist>
PLIST

# Use a stable self-signed identity if present so macOS keeps permission grants across rebuilds.
IDENTITY="${MURMRFLOW_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  if security find-identity -v -p codesigning | grep -q '"Murmrflow Dev"'; then IDENTITY="Murmrflow Dev"; else IDENTITY="-"; fi
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"
