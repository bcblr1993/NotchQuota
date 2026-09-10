#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '\n' < VERSION)"
APP="$ROOT/build/NotchQuota.app"
swift build -c release --triple arm64-apple-macosx13.0
BIN_DIR="$(swift build -c release --triple arm64-apple-macosx13.0 --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/NotchQuota" "$APP/Contents/MacOS/NotchQuota"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD_NUMBER:-$VERSION}" "$APP/Contents/Info.plist"
cp -R "$BIN_DIR/NotchQuota_NotchQuota.bundle" "$APP/Contents/Resources/"
cp Packaging/AppIcon.icns "$APP/Contents/Resources/"
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
if [ -n "${SIGNING_IDENTITY:-}" ]; then
  for COMPONENT in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$FRAMEWORK/Versions/B/$COMPONENT"
  done
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$FRAMEWORK"
fi
# SwiftPM's generated resource accessor also checks beside the main bundle.
# The app ships the resource bundle inside its own Resources; ResourceLocator selects it explicitly.
if [ -n "${SIGNING_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
printf 'Built %s (%s)\n' "$APP" "$VERSION"
