#!/usr/bin/env bash
# M7's screenshots, made by the app itself under MEETINGCAPTURE_E2E=1 with invented data
# (scripts/app-demo-home.sh): the library with a report, Recording, Paused and Processing,
# each in Phosphor and Paper, plus the menu bar extra's four states. Nothing is recorded:
# DemoState.swift fakes the states, and the user's config and folders are never read.
#
#   scripts/app-snapshots.sh [out dir]    → default dev/tmp/m7-shots (gitignored)
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-dev/tmp/m7-shots}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
swift build --product MeetingCaptureDesktop 2>&1 | grep -E 'error:' && exit 1
bin=".build/debug/MeetingCaptureDesktop"
home="$(scripts/app-demo-home.sh)"
trap 'rm -rf "$home"' EXIT

shoot() { # $1 theme, $2 demo
    rm -f "$out/$1-$2.png"
    MEETINGCAPTURE_E2E=1 MEETINGCAPTURE_HOME="$home" MEETINGCAPTURE_THEME="$1" MEETINGCAPTURE_DEMO="$2" \
        MEETINGCAPTURE_SNAPSHOT="$out/$1-$2.png" perl -e 'alarm shift; exec @ARGV' 30 "$bin" >/dev/null 2>&1 || true
    [[ -s "$out/$1-$2.png" ]] || { echo "app-snapshots: no picture for $1 $2" >&2; exit 1; }
}
for theme in phosphor paper; do
    for demo in library recording paused processing; do shoot "$theme" "$demo"; done
done
rm -f "$out/menubar.png"
MEETINGCAPTURE_E2E=1 MEETINGCAPTURE_HOME="$home" MEETINGCAPTURE_MENUBAR_SNAPSHOT="$out/menubar.png" \
    perl -e 'alarm shift; exec @ARGV' 30 "$bin" >/dev/null 2>&1 || true
[[ -s "$out/menubar.png" ]] || { echo "app-snapshots: no menu bar picture" >&2; exit 1; }
n="$(find "$out" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
echo "app-snapshots: $n pictures in $out"
