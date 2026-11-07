#!/usr/bin/env bash
# Spends subscription usage: the M5.2 👤 check (spec 05.2). From the invented series in
# Tests/Fixtures/live/group/, it writes week 1's report, then week 2's twice: once in a
# group with week 1 (so week 1's report goes as context, never its transcript) and once
# on its own. Both land in dev/tmp/live-group/ for the user to compare. About 12 to 15
# CLI calls in all. Like live-report.sh it refuses an API-profile route and sets
# MEETINGCAPTURE_CLI_ONLY=1, so it never spends an API key.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2
CONFIG="$HOME/.config/MeetingCapture/config.json"
if [ -f "$CONFIG" ] && grep -q '"llmRoute"[[:space:]]*:[[:space:]]*"apiProfile"' "$CONFIG"; then
    echo "live-group-report: the settings route summaries to an API profile, so nothing was run." >&2
    exit 2
fi
if ! command -v claude >/dev/null 2>&1 && ! command -v codex >/dev/null 2>&1; then
    echo "live-group-report: neither the claude nor the codex CLI is on PATH, so nothing was run." >&2
    exit 2
fi
OUT="dev/tmp/live-group"
rm -rf "$OUT"
mkdir -p "$OUT/with" "$OUT/without"
SRC="Tests/Fixtures/live/group"
sidecar() { # base, createdAt
    printf '{"version":1,"createdAt":"%s","state":"processed","speakerNames":{}}\n' "$2" > "$1.mcmeta.json"
}
cp "$SRC/week1.txt" "$OUT/with/meeting_20260220_100000.txt"
cp "$SRC/week2.txt" "$OUT/with/meeting_20260227_100000.txt"
cp "$SRC/week2.txt" "$OUT/without/meeting_20260227_100000.txt"
sidecar "$OUT/with/meeting_20260220_100000" "2026-02-20T10:00:00Z"
sidecar "$OUT/with/meeting_20260227_100000" "2026-02-27T10:00:00Z"
sidecar "$OUT/without/meeting_20260227_100000" "2026-02-27T10:00:00Z"
cat > "$OUT/with/groups.json" <<'JSON'
{"version":1,"groups":[{"id":"demo-book-sale","name":"Book sale planning","members":["meeting_20260220_100000","meeting_20260227_100000"],"redactContext":true}]}
JSON
run() { # transcript path, log name
    MEETINGCAPTURE_CLI_ONLY=1 perl -e 'alarm shift; exec @ARGV' 1800 .build/debug/MeetingCaptureCLI --summarize-only "$1" \
        > "$OUT/$2.log" 2>&1 || { echo "   failed, see $OUT/$2.log"; return 1; }
    grep -E '^🌐|^❌' "$OUT/$2.log" || true
}
status=0
echo "── week 1 (the group's earlier report)"; run "$OUT/with/meeting_20260220_100000.txt" week1 || status=1
echo "── week 2 with the group's context"; run "$OUT/with/meeting_20260227_100000.txt" week2-with || status=1
echo "── week 2 on its own"; run "$OUT/without/meeting_20260227_100000.txt" week2-without || status=1
ls "$OUT"/with/*.html "$OUT"/without/*.html 2>/dev/null
exit "$status"
