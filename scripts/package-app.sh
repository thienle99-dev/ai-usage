#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
swift build -c release
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcodebuild \
  -project "$ROOT/AIUsageWidget.xcodeproj" \
  -scheme AIUsageWidget \
  -configuration Release \
  -sdk macosx \
  -derivedDataPath "$ROOT/.build/widget-derived" \
  CODE_SIGNING_ALLOWED=NO \
  build
APP="$ROOT/dist/AI Usage Monitor.app"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/AIUsage "$APP/Contents/MacOS/AIUsage"
mkdir -p "$APP/Contents/PlugIns"
WIDGET_BUNDLE="$APP/Contents/PlugIns/AIUsageWidget.appex"
if [ -d "$WIDGET_BUNDLE" ]; then
  rm -rf "$WIDGET_BUNDLE"
fi
cp -R "$ROOT/.build/widget-derived/Build/Products/Release/AIUsageWidget.appex" "$WIDGET_BUNDLE"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>AIUsage</string><key>CFBundleIdentifier</key><string>com.local.aiusage</string><key>CFBundleName</key><string>AI Usage Monitor</string><key>CFBundleDisplayName</key><string>AI Usage Monitor</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0</string><key>CFBundleVersion</key><string>1</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/></dict></plist>
PLIST
codesign --force --sign - --entitlements "$ROOT/Support/AIUsageWidget.entitlements" "$APP/Contents/PlugIns/AIUsageWidget.appex"
codesign --force --sign - --entitlements "$ROOT/Support/AIUsage.entitlements" "$APP/Contents/MacOS/AIUsage"
codesign --force --sign - --entitlements "$ROOT/Support/AIUsage.entitlements" "$APP"
echo "Created $APP"
