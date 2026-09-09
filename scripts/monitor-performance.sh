#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${3:-$HOME/Library/Logs/NotchQuota/Performance}"
mkdir -p "$ROOT/.build/performance" "$OUT"
PROBE="$ROOT/.build/performance/probe"
if [ ! -x "$PROBE" ] || [ "$ROOT/scripts/performance-probe.swift" -nt "$PROBE" ]; then
  xcrun swiftc -O "$ROOT/scripts/performance-probe.swift" -o "$PROBE"
fi
FILE="$OUT/sample-$(date -u +%Y%m%dT%H%M%SZ)-$$.jsonl"
"$PROBE" "${1:-240}" "${2:-10}" > "$FILE"
printf '%s\n' "$FILE"
