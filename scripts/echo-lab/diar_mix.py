#!/usr/bin/env python
"""Builds system-track fixtures with a known speaker count, for choosing the speaker
detection threshold: one voice, then two and three in turns. Only invented words: the
synthetic other side, the user's solo lines from main-3, and a macOS `say` voice."""
import subprocess
import tempfile
from pathlib import Path

import numpy as np

import lab

OUT = lab.LAB / "diar"
mic, sys_track = lab.load_take("main-3")
off = lab.playback_offset(sys_track, "main-3")
them = [sys_track[int(e["start"] * lab.SR) : int(e["end"] * lab.SR)] for e in lab.events(off, ("them",))
        if e["section"].startswith(("S1", "S3"))]
you = [mic[int(e["start"] * lab.SR) : int(e["end"] * lab.SR)] for e in lab.events(off, ("you",))
       if e["section"].startswith("S2")]
lines = [e["text"] for e in lab.events(off, ("them",)) if e["section"].startswith("S3")][:6]
said = []
with tempfile.TemporaryDirectory() as d:
    for i, text in enumerate(lines):
        f = Path(d, f"{i}.wav")
        subprocess.run(["say", "-v", "Samantha", "-o", str(f), "--data-format=LEI16@48000", text], check=True)
        said.append(lab.read_wav(f)[0][:, 0])


def level(x, db=-28):
    return x * 10 ** (db / 20) / max(np.sqrt(np.mean(x**2)), 1e-9)


def mix(groups):
    gap = np.zeros(int(0.5 * lab.SR), dtype=np.float32)
    parts = []
    for i in range(max(len(g) for g in groups)):
        for g in groups:
            if i < len(g):
                parts += [level(g[i]).astype(np.float32), gap]
    return np.concatenate(parts)


lab.write_wav(OUT / "one.wav", mix([them]))
lab.write_wav(OUT / "two.wav", mix([them[:8], you]))
lab.write_wav(OUT / "three.wav", mix([them[:6], you, said]))
print({k: round(len(lab.read_wav(OUT / f"{k}.wav")[0]) / lab.SR) for k in ("one", "two", "three")})
