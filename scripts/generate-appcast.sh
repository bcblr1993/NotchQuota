#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(tr -d '\n' < VERSION)"
ARCHIVE="$ROOT/dist/NotchQuota-$VERSION-macos-arm64.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/notchquota-appcast.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
cp "$ARCHIVE" "$STAGE/"
GENERATOR="$ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
ARGS=(--download-url-prefix "https://github.com/bcblr1993/NotchQuota/releases/download/v$VERSION/" "$STAGE")
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATOR" --ed-key-file - "${ARGS[@]}"
else
  "$GENERATOR" --account NotchQuota "${ARGS[@]}"
fi
cp "$STAGE/appcast.xml" "$ROOT/dist/appcast.xml"
python3 - "$ROOT/dist/appcast.xml" "$VERSION" <<'PY'
import sys,xml.etree.ElementTree as E
root=E.parse(sys.argv[1]); ns={'s':'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items=root.findall('./channel/item'); assert len(items)==1
item=items[0]; assert item.findtext('s:version',namespaces=ns)==sys.argv[2]
enclosure=item.find('enclosure')
assert enclosure.get('{'+ns['s']+'}edSignature') and int(enclosure.get('length'))>0
assert enclosure.get('url')=='https://github.com/bcblr1993/NotchQuota/releases/download/v'+sys.argv[2]+'/NotchQuota-'+sys.argv[2]+'-macos-arm64.dmg'
print('Appcast version, URL and archive signature metadata verified.')
PY
