#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="${1:-$HOME/Library/Logs/NotchQuota/Performance/animation-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
# Build separately first; do not replace the user's installed signed application.
APP="$ROOT/build/NotchQuota.app/Contents/MacOS/NotchQuota"
if [ ! -x "$APP" ]; then echo 'Run scripts/build-app.sh first.' >&2; exit 1; fi
# Restrict inherited environment, including when attaching Instruments later.
env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$APP" --animation-test > "$OUT/scenarios.jsonl" &
TEST_PID=$!
trap 'kill "$TEST_PID" 2>/dev/null || true' EXIT
# Bounded watchdog only for the process started above, never other applications.
for ((i=0; i<250; i++)); do
  if ! kill -0 "$TEST_PID" 2>/dev/null; then
    wait "$TEST_PID"
    printf 'Animation scenarios: %s\n' "$OUT/scenarios.jsonl"
    exit 0
  fi
  sleep 1
done
echo 'Animation scenarios timed out after 250 seconds.' >&2
exit 1
