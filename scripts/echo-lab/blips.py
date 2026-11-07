#!/usr/bin/env python
"""Does a short far-side sound take the user's voice with it? Usage: blips.py <seconds> <every>...

The user's real speech from part 2 runs on, with part 1's real echo and reference let through
only as short blips, after 30 s of far side alone, like "mm-hm" while the user presents.
Prints how much of the voice survives in the windows that reach a blip, by projecting the
output onto the known voice (1.0 is untouched), and how much echo comes off during blips.
Scripted take only.
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


def run(length, every):
    sim = lab.build_sim("main-3")
    n = len(sim["mic"])
    start = sim["single"][1]
    voice = sim["near"]
    echo, ref = sim["echo"].copy(), sim["ref"].copy()
    # After the far side's 30 s, only blips, drawn from speech further on in part 1.
    mask = np.zeros(n, dtype=bool)
    at = start + int(every * lab.SR)
    centres = []
    while at + length * lab.SR < n:
        mask[at : at + int(length * lab.SR)] = True
        centres.append(at)
        at += int(every * lab.SR)
    room = np.median(np.abs(echo))
    tail = np.arange(n) >= start
    keep = ~tail | mask
    noise = np.random.default_rng(1).normal(0, max(room, 1e-5), n).astype(np.float32)
    mic = np.where(keep, echo, noise) + voice
    ref = np.where(keep, ref, 0)
    with tempfile.TemporaryDirectory(dir=lab.LAB) as d:
        two, one = Path(d, "two.wav"), Path(d, "one.wav")
        with wave.open(str(two), "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(lab.SR)
            w.writeframes((np.clip(np.stack([mic, ref], axis=1), -1, 1) * 32767).astype(np.int16).tobytes())
        env = dict(os.environ, MEETINGCAPTURE_E2E="1")
        subprocess.run([str(lab.REPO / ".build/release/MeetingCaptureCLI"), "--clean-echo", str(two), "--clean-echo-out", str(one)],
                       check=True, env=env, capture_output=True)
        if not one.exists():
            print(json.dumps({"blip_s": length, "every_s": every, "no_echo_found": True}))
            return
        out = lab.read_wav(one)[0][:, 0]
    keeps, cuts = [], []
    for c in centres:
        a, b = c, c + int(length * lab.SR)
        v = voice[a:b]
        if np.dot(v, v) < 1e-3 * len(v) * np.mean(voice[voice != 0] ** 2):
            continue
        g = float(np.dot(out[a:b], v) / np.dot(v, v))
        keeps.append(g)
        left = out[a:b] - g * v
        cuts.append(10 * np.log10(np.dot(echo[a:b], echo[a:b]) / max(np.dot(left, left), 1e-12)))
    # Beside the blips too, since a fit spreads 8 s either way.
    print(json.dumps({"blip_s": length, "every_s": every, "blips": len(keeps),
                      "voice_median": round(float(np.median(keeps)), 3), "voice_worst": round(float(np.min(keeps)), 3),
                      "echo_off_median_db": round(float(np.median(cuts)), 1)}), flush=True)


if __name__ == "__main__":
    args = [float(a) for a in sys.argv[1:]]
    for i in range(0, len(args), 2):
        run(args[i], args[i + 1])
