#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-$ROOT/build/NotchQuota.app}"
VERSION="$(tr -d '\n' < "$ROOT/VERSION")"
file "$APP/Contents/MacOS/NotchQuota" | grep -q arm64
codesign --verify --deep --strict "$APP"
ACTUAL="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$ACTUAL" = "$VERSION" ]
[ -f "$APP/Contents/Resources/AppIcon.icns" ]
[ -d "$APP/Contents/Resources/NotchQuota_NotchQuota.bundle" ]
printf 'Release layout verified: %s arm64\n' "$VERSION"
