#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
APP_VERSION=${APP_VERSION:-1.0.0}
APP_BUILD=${APP_BUILD:-$APP_VERSION}
SIGN_IDENTITY=${CODE_SIGN_IDENTITY:--}
case "$APP_VERSION:$APP_BUILD" in
  *[!A-Za-z0-9._:-]*) echo "APP_VERSION and APP_BUILD may contain only letters, numbers, dots, underscores, and hyphens" >&2; exit 2 ;;
esac
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  case "$SPARKLE_PUBLIC_ED_KEY" in
    *[!A-Za-z0-9+/=]*) echo "SPARKLE_PUBLIC_ED_KEY must be base64" >&2; exit 2 ;;
  esac
fi
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONSET="$ROOT/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/create-app-icon.swift" "$ROOT/web/public/favicon.svg" "$ICONSET"
iconutil --convert icns --output "$APP/Contents/Resources/AppIcon.icns" "$ICONSET"
cp .build/release/AIUsage "$APP/Contents/MacOS/AIUsage"
cp -R .build/release/AIUsage_AIUsage.bundle "$APP/Contents/Resources/"
cp -R "$ROOT/Sources/AIUsage/Resources/Localization/en.lproj" "$APP/Contents/Resources/"
cp -R "$ROOT/Sources/AIUsage/Resources/Localization/vi.lproj" "$APP/Contents/Resources/"
SPARKLE_FRAMEWORK=$(find "$ROOT/.build/artifacts/Sparkle" -type d -name Sparkle.framework -print -quit 2>/dev/null || true)
if [ -n "$SPARKLE_FRAMEWORK" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  fi
  cp -R "$SPARKLE_FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
for DEV_RPATH in \
  @loader_path/../artifacts/Sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64 \
  @loader_path/../../artifacts/Sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64 \
  @loader_path/../../../artifacts/Sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64
do
  install_name_tool -delete_rpath "$DEV_RPATH" "$APP/Contents/MacOS/AIUsage"
done
install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/AIUsage"
else
  echo "Sparkle.framework was not found in SwiftPM artifacts" >&2
  exit 1
fi
mkdir -p "$APP/Contents/PlugIns"
WIDGET_BUNDLE="$APP/Contents/PlugIns/AIUsageWidget.appex"
if [ -d "$WIDGET_BUNDLE" ]; then
  rm -rf "$WIDGET_BUNDLE"
fi
cp -R "$ROOT/.build/widget-derived/Build/Products/Release/AIUsageWidget.appex" "$WIDGET_BUNDLE"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>AIUsage</string><key>CFBundleIdentifier</key><string>com.local.aiusage</string><key>CFBundleName</key><string>AI Usage Monitor</string><key>CFBundleDisplayName</key><string>AI Usage Monitor</string><key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>$APP_VERSION</string><key>CFBundleVersion</key><string>$APP_BUILD</string><key>LSMinimumSystemVersion</key><string>14.0</string><key>LSUIElement</key><true/><key>CFBundleLocalizations</key><array><string>en</string><string>vi</string></array><key>SUFeedURL</key><string>https://github.com/thienle99-dev/ai-usage/releases/latest/download/appcast.xml</string></dict></plist>
PLIST
if [ -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]; then
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$APP/Contents/Info.plist"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
  codesign --force --sign - --entitlements "$ROOT/Support/AIUsageWidget.entitlements" "$APP/Contents/PlugIns/AIUsageWidget.appex"
  codesign --force --sign - --entitlements "$ROOT/Support/AIUsage.entitlements" "$APP/Contents/MacOS/AIUsage"
  codesign --force --sign - --entitlements "$ROOT/Support/AIUsage.entitlements" "$APP"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Support/AIUsageWidget.entitlements" "$APP/Contents/PlugIns/AIUsageWidget.appex"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Support/AIUsage.entitlements" "$APP/Contents/MacOS/AIUsage"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" --entitlements "$ROOT/Support/AIUsage.entitlements" "$APP"
fi
echo "Created $APP"
