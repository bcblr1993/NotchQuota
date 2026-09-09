#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '\n' < VERSION)"
APP="$ROOT/build/NotchQuota.app"
OUT="$ROOT/dist"
mkdir -p "$OUT"
if [ ! -d "$APP" ]; then echo 'Run scripts/build-app.sh first.' >&2; exit 1; fi
NAME="NotchQuota-$VERSION-macos-arm64"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/notchquota-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp docs/安装说明.txt "$STAGE/安装说明.txt"
hdiutil create -volname NotchQuota -srcfolder "$STAGE" -ov -format UDZO "$OUT/$NAME.dmg" >/dev/null
if [ -n "${SIGNING_IDENTITY:-}" ]; then codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$OUT/$NAME.dmg"; fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$OUT/$NAME.dmg" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 10m --output-format json > "$OUT/notarization.json"
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print("Notarization:", d.get("status")); sys.exit(0 if d.get("status")=="Accepted" else 1)' "$OUT/notarization.json"
  xcrun stapler staple "$OUT/$NAME.dmg"
  xcrun stapler validate "$OUT/$NAME.dmg"
  xcrun stapler staple "$APP"
  spctl --assess --type execute "$APP"
  spctl --assess --type open --context context:primary-signature "$OUT/$NAME.dmg"
fi
# App ZIP is useful for local development. Public releases use the notarized DMG.
ditto -c -k --keepParent "$APP" "$OUT/$NAME.zip"
(cd "$OUT" && shasum -a 256 "$NAME.dmg" > SHA256SUMS.txt)
printf 'Packaged %s\n' "$OUT/$NAME.dmg"
