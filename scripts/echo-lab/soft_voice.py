#!/usr/bin/env python
"""Does a soft voice talking over the echo lose lines to the label check?
Usage: soft_voice.py <gain dB>... (on main-3).

The user's real speech from part 2 is mixed over part 1's real echo at each gain, through the
real binary. Scored by how many of those lines' words appear under `You`, by word count only. Scripted take only.
"""
import json
import re
import subprocess
import sys
import tempfile
import wave
from collections import Counter
from pathlib import Path

import numpy as np

import lab
import words


def main(gains):
    for gain in gains:
        sim = lab.build_sim("main-3", near_gain_db=gain)
        with tempfile.TemporaryDirectory(dir=lab.LAB) as d:
            wav = Path(d, "sim.wav")
            with wave.open(str(wav), "wb") as w:
                w.setnchannels(2)
                w.setsampwidth(2)
                w.setframerate(lab.SR)
                w.writeframes((np.clip(np.stack([sim["mic"], sim["ref"]], axis=1), -1, 1) * 32767).astype(np.int16).tobytes())
            run = subprocess.run([str(words.BIN), "--transcribe-only", str(wav), "--model", words.MODEL, "--model-folder",
                                  str(words.FOLDER), "--language", "en"],
                                 check=True, capture_output=True, text=True, timeout=900)
            left = re.search(r"left out (\d+) mic line", run.stdout + run.stderr)
            lines = words.parse(wav.with_suffix(".txt"))
            heard = Counter(w for x in lines if x[1] == "You" for w in x[2])
            truth = Counter(w for e in lab.events(0) if e["kind"] == "you" and e["section"].startswith("S2")
                            for w in words.norm(e["text"]))
            print(json.dumps({"gain_db": gain, "left_out": int(left.group(1)) if left else 0,
                              "recall_pct": round(100 * sum((heard & truth).values()) / sum(truth.values()), 1)}), flush=True)


if __name__ == "__main__":
    main([float(a) for a in sys.argv[1:]])
