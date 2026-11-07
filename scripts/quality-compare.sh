#!/usr/bin/env bash
# Spends subscription usage, on invented transcripts only, and counts against the
# daily cap; the run checks the planned calls fit before starting. Compares answers
# with and without regex (D-19) and writes the result to dev/evidence/.
#   --redaction  the sections step alone, on Tests/Fixtures/redaction (M2)
#   --full       the whole report pipeline, one transcript per scenario (M4)
# Usage: quality-compare.sh --redaction|--full [claude|codex]
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

case "${1:-}" in
    --redaction) FLAG=--quality-compare-redaction; FIXTURES=Tests/Fixtures/redaction; NAME=redaction ;;
    --full) FLAG=--quality-compare-full; FIXTURES=Tests/Fixtures/scenarios; NAME=full ;;
    *) echo "usage: quality-compare.sh --redaction|--full [claude|codex]" >&2; exit 2 ;;
esac
CLI="${2:-claude}"
case "$CLI" in claude|codex) ;; *) echo "CLI must be claude or codex" >&2; exit 2 ;; esac

swift build 2>&1 | tail -1
OUT="dev/evidence/$(date +%Y-%m-%d)-quality-$NAME-$CLI.md"
perl -e 'alarm shift; exec @ARGV' 5400 .build/debug/MeetingCaptureCLI \
    "$FLAG" "$FIXTURES" --out "$OUT" --llm-cli "$CLI"
status=$?
echo "quality-compare: exit $status, results in $OUT"
exit "$status"
