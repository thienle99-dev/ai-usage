#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
swift build -c release
APP="$ROOT/dist/AI Usage Monitor.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AIUsage "$APP/Contents/MacOS/AIUsage"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>AIUsage</string><key>CFBundleIdentifier</key><string>com.local.aiusage</string><key>CFBundleName</key><string>AI Usage Monitor</string><key>CFBundleDisplayName</key><string>AI Usage Monitor</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/></dict></plist>
PLIST
echo "Created $APP"
