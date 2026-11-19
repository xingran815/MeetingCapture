#!/usr/bin/env python3
"""Scores the shipped EchoRemover on AEC-Challenge clips (github.com/microsoft/AEC-Challenge).

Each clip goes in as a 48 kHz two-track file (ch1 mic, ch2 far end), the way MeetingCapture
records, through `MeetingCaptureCLI --clean-echo`. Scores are taken at 16 kHz:
  ERLE    far-end single talk: 10*log10(mic power / output power), whole clip
  AECMOS  the challenge's own model (v4, 16 kHz): echo and other degradation, 1..5
  PESQ    synthetic double talk only: output against the clean near-end speech
Usage: eval.py <bench dir> <binary> [dev|test] [label]
The bench dir holds clips.json, data/clips and aecmos/; see README.md here.
"""
import json, os, subprocess, sys
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

sys.path.insert(0, str(Path(__file__).parent))
import eval_lib as ev  # noqa: E402

BENCH, BIN = Path(sys.argv[1]), sys.argv[2]
SPLIT = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != "all" else None
LABEL = sys.argv[4] if len(sys.argv) > 4 else "run"
WORK = BENCH / "work"
WORK.mkdir(exist_ok=True)


def remove_echo(name, mic, lpb):
    n = min(len(mic), len(lpb))
    st = np.stack([resample_poly(mic[:n], 3, 1), resample_poly(lpb[:n], 3, 1)], axis=1)
    inp, out = WORK / f"{name}_in48.wav", WORK / f"{name}_out48.wav"
    sf.write(inp, np.clip(st, -1, 1), 48000, subtype="PCM_16")
    if out.exists():
        out.unlink()
    env = dict(os.environ, MEETINGCAPTURE_E2E="1", MEETINGCAPTURE_AEC_LINEAR_DIR=str(WORK))
    r = subprocess.run([BIN, "--clean-echo", str(inp), "--clean-echo-out", str(out)],
                       capture_output=True, text=True, env=env, timeout=300)
    if r.returncode != 0:
        raise RuntimeError(r.stderr)
    if not out.exists():  # "No echo found": the user gets the raw mic
        return mic[:n].copy(), "no-echo"
    y, _ = sf.read(out, dtype="float64")
    y = resample_poly(y, 1, 3)[:n]
    sf.write(WORK / f"{name}_out16.wav", y, 16000, subtype="FLOAT")
    return np.pad(y, (0, n - len(y))), r.stdout.strip()


rows = ev.score_all(BENCH, SPLIT, remove_echo, verbose=True)
json.dump(rows, open(BENCH / f"results_{LABEL}.json", "w"), indent=1, default=float)
ev.summary([r for r in rows if r["split"] == "dev"], LABEL + " dev")
ev.summary([r for r in rows if r["split"] == "test"], LABEL + " test")
