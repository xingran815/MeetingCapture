#!/usr/bin/env bash
# Spends subscription usage: builds a real report from each invented transcript in
# Tests/Fixtures/live/ (a meeting and a therapy session) into dev/tmp/live-report/,
# for the user to read (spec 04's 👤 check). About 8 to 10 CLI calls in all.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2
OUT="dev/tmp/live-report"
mkdir -p "$OUT"
status=0
for src in Tests/Fixtures/live/*.txt; do
    [ -e "$src" ] || { echo "no fixtures in Tests/Fixtures/live" >&2; exit 2; }
    name="$(basename "$src")"
    cp "$src" "$OUT/$name"
    echo "── $name"
    perl -e 'alarm shift; exec @ARGV' 1800 .build/debug/MeetingCaptureCLI --summarize-only "$OUT/$name" \
        > "$OUT/${name%.txt}.log" 2>&1 || { echo "   failed, see $OUT/${name%.txt}.log"; status=1; }
    grep -E '^🌐|^❌' "$OUT/${name%.txt}.log" || true
done
exit "$status"
