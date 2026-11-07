#!/usr/bin/env bash
# Spends subscription usage: builds a real report from each invented transcript in
# Tests/Fixtures/live/ (a meeting and a therapy session) into dev/tmp/live-report/,
# for the user to read (spec 04's 👤 check). About 8 to 10 CLI calls in all.
# It refuses to run when the settings would send the calls to an API profile
# instead, and MEETINGCAPTURE_CLI_ONLY=1 makes the binary refuse the API
# fallback when no CLI is ready, so it never spends an API key (M4 deep review).
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2
CONFIG="$HOME/.config/MeetingCapture/config.json"
if [ -f "$CONFIG" ] && grep -q '"llmRoute"[[:space:]]*:[[:space:]]*"apiProfile"' "$CONFIG"; then
    echo "live-report: the settings route summaries to an API profile, so nothing was run." >&2
    exit 2
fi
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
    echo "live-report: neither the claude nor the codex CLI is on PATH, so nothing was run." >&2
    exit 2
fi
OUT="dev/tmp/live-report"
mkdir -p "$OUT"
status=0
for src in Tests/Fixtures/live/*.txt; do
    [ -e "$src" ] || { echo "no fixtures in Tests/Fixtures/live" >&2; exit 2; }
    name="$(basename "$src")"
    cp "$src" "$OUT/$name"
    echo "── $name"
    MEETINGCAPTURE_CLI_ONLY=1 perl -e 'alarm shift; exec @ARGV' 1800 .build/debug/MeetingCaptureCLI --summarize-only "$OUT/$name" \
        > "$OUT/${name%.txt}.log" 2>&1 || { echo "   failed, see $OUT/${name%.txt}.log"; status=1; }
    grep -E '^🌐|^❌' "$OUT/${name%.txt}.log" || true
done
exit "$status"
