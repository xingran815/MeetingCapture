#!/usr/bin/env bash
# Spends subscription usage, on invented transcripts only, and counts against the
# daily cap. Compares answers with and without regex (D-19) and writes the result
# to dev/evidence/. Usage: quality-compare.sh --redaction [claude|codex]
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

[ "${1:-}" = "--redaction" ] || { echo "usage: quality-compare.sh --redaction [claude|codex]" >&2; exit 2; }
CLI="${2:-claude}"
case "$CLI" in claude|codex) ;; *) echo "CLI must be claude or codex" >&2; exit 2 ;; esac

swift build 2>&1 | tail -1
OUT="dev/evidence/$(date +%Y-%m-%d)-quality-redaction-$CLI.md"
perl -e 'alarm shift; exec @ARGV' 3000 .build/debug/MeetingCaptureCLI \
    --quality-compare-redaction Tests/Fixtures/redaction --out "$OUT" --llm-cli "$CLI"
status=$?
echo "quality-compare: exit $status, results in $OUT"
exit "$status"
