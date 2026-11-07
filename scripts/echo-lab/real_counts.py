#!/usr/bin/env python3
"""Before-and-after echo counts on the user's real calls. PRIVATE AUDIO: this prints only
counts. It never prints a line of text, and its transcripts stay in a temporary folder
that it deletes, so no words can reach a log or a model.

A `You` word counts as a repeat if its line mostly repeats the other side's words within
6 seconds. That's the same rough count the M3.2 spec's "about a third" came from.
"""
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HF = Path.home() / "Documents/huggingface/models/argmaxinc/whisperkit-coreml/openai_whisper-small"
BIN = Path(__file__).resolve().parents[2] / ".build/release/MeetingCaptureCLI"
SRC = Path.home() / "Documents/MeetingCapture"


def parse(path):
    out = []
    for line in Path(path).read_text().splitlines():
        m = re.match(r"\[(\d+):(\d+):(\d+)\] (.+?): (.*)", line)
        if m:
            h, mi, s, who, text = m.groups()
            out.append((int(h) * 3600 + int(mi) * 60 + int(s), who, re.findall(r"[a-z']+|[^\W\d_]", text.lower())))
    return out


def count(lines):
    you = [x for x in lines if x[1] == "You"]
    other = [x for x in lines if x[1] != "You"]
    words = repeated = 0
    for t, _, ws in you:
        near = {w for ot, _, ow in other if abs(ot - t) <= 6 for w in ow}
        words += len(ws)
        if ws and sum(w in near for w in ws) / len(ws) >= 0.6:
            repeated += len(ws)
    return {"you_lines": len(you), "you_words": words, "repeat_words": repeated,
            "repeat_pct": round(100 * repeated / max(words, 1), 1), "speakers": len({x[1] for x in other})}


for name in sys.argv[1:]:
    before = count(parse(SRC / f"{name}.txt")) if (SRC / f"{name}.txt").exists() else None
    with tempfile.TemporaryDirectory() as d:
        shutil.copy(SRC / f"{name}.m4a", d)
        subprocess.run(
            [str(BIN), "--transcribe-only", f"{name}.m4a", "--model", "openai_whisper-small",
             "--model-folder", str(HF)],
            cwd=d, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1200,
        )
        print(name, "before", before, "after", count(parse(Path(d, f"{name}.txt"))), flush=True)
