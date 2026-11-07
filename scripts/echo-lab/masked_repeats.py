#!/usr/bin/env python
"""Whether the user's repeat lines survive, with no way for an echo to pass as one.
Usage: masked_repeats.py <take>.

`words.py` can't tell: relabel the other side as `You` and its repeat score stays high, since
an echo of a line has the same words as its repeat. So this keeps only the gaps after each
far-side line in S5, silences everything else on both tracks, and transcribes that from the
raw mic and from the product's cleaned mic. Scripted takes only (lab.TAKES).
"""
import json
import os
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

import numpy as np

import lab
import words


def write(path, mic, ref):
    n = min(len(mic), len(ref))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(lab.SR)
        w.writeframes((np.clip(np.stack([mic[:n], ref[:n]], axis=1), -1, 1) * 32767).astype(np.int16).tobytes())


def main(take):
    mic, ref = lab.load_take(take)
    off = lab.playback_offset(ref, take)
    events = sorted((e for e in lab.events(off) if (e.get("section") or "").startswith("S5")), key=lambda e: e["start"])
    gaps = []
    for e, nxt in zip(events, events[1:] + [None]):
        if e["kind"] == "them":
            # Up to the next far-side sound, whatever kind it is. A `you` line isn't one.
            later = [x["start"] for x in events if x["start"] > e["end"] and x["kind"] != "you"]
            gaps.append((e["end"] + 0.3, later[0] if later else e["end"] + 8))
    keep = np.zeros(len(mic), dtype=bool)
    for a, b in gaps:
        keep[int(a * lab.SR) : int(b * lab.SR)] = True
    with tempfile.TemporaryDirectory(dir=lab.LAB) as d:
        two, clean = Path(d, "two.wav"), Path(d, "clean.wav")
        write(two, mic, ref)
        env = dict(os.environ, MEETINGCAPTURE_E2E="1")
        subprocess.run([str(words.BIN), "--clean-echo", str(two), "--clean-echo-out", str(clean)],
                       check=True, env=env, stdout=subprocess.DEVNULL)
        cleaned = lab.read_wav(clean)[0][:, 0]
        for name, track in (("raw", mic), ("cleaned", cleaned)):
            n = min(len(track), len(keep))
            wav = Path(d, f"{name}.wav")
            write(wav, track[:n] * keep[:n], ref[:n] * keep[:n])
            subprocess.run([str(words.BIN), "--transcribe-only", str(wav), "--model", words.MODEL, "--model-folder",
                            str(words.FOLDER), "--language", "en", "--no-aec"],
                           check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=900)
            res = words.score(words.parse(wav.with_suffix(".txt")), off, take)
            print(json.dumps({"take": take, "from": name, "gaps": len(gaps), "repeat_kept_pct": res["repeat_kept_pct"],
                              "repeats": res["repeats_20_29"]}), flush=True)


if __name__ == "__main__":
    main(sys.argv[1])
