#!/usr/bin/env bash
# Writes an invented library for app screenshots (spec 07): a home folder whose output
# folder holds a few reports, one group and an unfinished-looking report-less transcript.
# Every name, line and number is made up. Use it with MEETINGCAPTURE_E2E=1:
#
#   home="$(scripts/app-demo-home.sh)"
#   MEETINGCAPTURE_E2E=1 MEETINGCAPTURE_HOME="$home" MEETINGCAPTURE_THEME=paper \
#       MEETINGCAPTURE_DEMO=library .build/MeetingCapture.app/Contents/MacOS/MeetingCapture
#
# MEETINGCAPTURE_DEMO also takes recording, paused and processing (DemoState.swift).
#   scripts/app-demo-home.sh [dir]   → prints the home folder it wrote (a new temp one by default)
set -euo pipefail

home="${1:-$(mktemp -d "${TMPDIR:-/tmp}/mc-demo-home.XXXXXX")}"
out="$home/Documents/MeetingCapture"
mkdir -p "$out" "$home/.config/MeetingCapture"

python3 -I - "$out" <<'PY'
import json, sys, os, datetime
out = sys.argv[1]
today = datetime.date.today()

def stamp(days_ago, hhmm):
    d = today - datetime.timedelta(days=days_ago)
    return d.strftime("%Y%m%d") + "_" + hhmm + "00"

def report(topic, scenario, title, minutes, sections, transcript, reviewed=True, notices=()):
    return {
        "schemaVersion": 1, "topic": topic, "scenario": scenario, "scenarioTitle": title,
        "createdAt": "", "durationSeconds": minutes * 60, "language": "en",
        "models": {"cheap": "haiku", "normal": "sonnet", "frontier": "opus"},
        "reviewed": reviewed, "notices": list(notices), "sections": sections,
        "reviewChanges": [], "transcript": transcript,
    }

def line(t, who, text):
    return {"start": t, "end": t + 4, "speaker": who, "text": text}

atlas_tx = [
    line(721, "You", "Okay, export first. Where are we?"),
    line(724, "Speaker 1", "Shipped Tuesday, the flag is at zero."),
    line(731, "Speaker 2", "I'd go to ten percent this week."),
    line(735, "You", "Agreed. Search next?"),
    line(739, "Speaker 1", "Still around 420 milliseconds at p95."),
    line(746, "Speaker 2", "Then the target needs a definition."),
]
atlas = report("Atlas sprint review", "meeting", "Meeting", 42.3, [
    {"id": "summary", "title": "Summary", "kind": "prose", "items": [
        {"text": "The team closed sprint 14 with the export flow shipped behind a flag. Search latency is still above target and will be profiled before planning. The release date holds at 1 Dec if the migration test passes on Thursday.",
         "priority": "high", "keywords": ["1 Dec"]}]},
    {"id": "decisions", "title": "Decisions", "kind": "bullets", "items": [
        {"text": "Ship export behind a flag, 10% first", "keywords": ["10% first"]},
        {"text": "Release stays 1 Dec", "source": "earlier"},
        {"text": "Drop the CSV v1 endpoint in sprint 16"}]},
    {"id": "actions", "title": "Action items", "kind": "actions", "items": [
        {"text": "Profile search on the staging index", "owner": "Speaker 1", "due": "18 Nov", "priority": "high"},
        {"text": "Run the migration test on a copy of the data", "owner": "Speaker 2", "due": "20 Nov"},
        {"text": "Draft new onboarding copy", "owner": "You", "due": "21 Nov"}]},
    {"id": "questions", "title": "Open questions", "kind": "bullets", "items": [
        {"text": "Who signs off the onboarding copy?"},
        {"text": "Is the 300 ms search target p50 or p95?"}]},
], atlas_tx)

planning = report("Atlas planning", "meeting", "Meeting", 51, [
    {"id": "summary", "title": "Summary", "kind": "prose", "items": [
        {"text": "Sprint 14 scope agreed: export behind a flag, search profiling, migration dry run."}]},
], [line(10, "You", "Let's agree the scope."), line(15, "Speaker 1", "Export, search, migration.")])

one = report("Weekly 1:1", "one_on_one", "One-on-one", 28.5, [
    {"id": "summary", "title": "Summary", "kind": "prose", "items": [
        {"text": "Talked through workload and the conference talk. Workload is fine; the talk outline is due next week."}]},
], [line(5, "You", "How's the workload?"), line(9, "Speaker 1", "Fine, the talk is the big thing.")])

lecture = report("Distributed systems, lecture 7", "lecture", "Lecture", 82.7, [
    {"id": "summary", "title": "Summary", "kind": "prose", "items": [
        {"text": "Consensus with Raft: leader election, log replication, and why a majority is enough."}]},
], [line(30, "Speaker 1", "Today we look at leader election.")], reviewed=False,
   notices=["The review step didn't run, so this is the first draft."])

items = [
    (stamp(0, "0915"), atlas, ["You", "Speaker 1", "Speaker 2"]),
    (stamp(7, "0915"), planning, ["You", "Speaker 1"]),
    (stamp(1, "1400"), one, ["You", "Speaker 1"]),
    (stamp(3, "1000"), lecture, ["Speaker 1"]),
]
for base, rep, _ in items:
    rep["createdAt"] = base[:4] + "-" + base[4:6] + "-" + base[6:8] + " " + base[9:11] + ":" + base[11:13]
    with open(os.path.join(out, base + ".report.json"), "w") as f:
        json.dump(rep, f, indent=1)
    # The library dates a report with no sidecar by its file; macOS moves the creation
    # date back with an earlier modification date.
    when = datetime.datetime.strptime(base, "%Y%m%d_%H%M%S").timestamp()
    os.utime(os.path.join(out, base + ".report.json"), (when, when))
    with open(os.path.join(out, base + ".txt"), "w") as f:
        for e in rep["transcript"]:
            s = int(e["start"])
            f.write("[%02d:%02d:%02d] %s: %s\n" % (s // 3600, s // 60 % 60, s % 60, e["speaker"], e["text"]))

with open(os.path.join(out, "groups.json"), "w") as f:
    json.dump({"version": 1, "groups": [{"id": "demo-atlas", "name": "Project Atlas weekly",
        "members": [items[0][0], items[1][0]], "redactContext": True}]}, f, indent=1)
PY
printf '%s\n' "$home"
