#!/usr/bin/env python3
"""Scores the built binary on the real full-band test sessions (real_data.py keeps 10 whole
sessions in <bench>/rfb/clips, never trained on) at 48 kHz.

  rfb_eval.py <bench> <binary> [label]

Real recordings have no clean near end, so only scores that need none:
  - far-end single talk: AECMOS echo, ERLE whole band and 8-24 kHz
  - double talk: AECMOS echo and degradation (the 48 kHz model is non-intrusive)
Unsure: 10 sessions is a small test; a difference under about 0.1 MOS may be noise.
Writes <bench>/rfb/results_<label>.json.
"""
import json, sys
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fb_eval import aecmos, clean, erle  # noqa: E402


def main():
    bench, binary = Path(sys.argv[1]), sys.argv[2]
    label = sys.argv[3] if len(sys.argv) > 3 else "run"
    rows = []
    for c in json.load(open(bench / "rfb/clips.json")):
        p = lambda k: sf.read(bench / f"rfb/clips/{c['session']}_{k}.wav", dtype="float64")[0]
        echo, lpb = p("farend-singletalk_mic"), p("farend-singletalk_lpb")
        n = min(len(echo), len(lpb))
        echo, lpb = echo[:n], lpb[:n]
        y = clean(binary, echo, lpb)
        e_raw, _ = aecmos(bench, "st", lpb, echo, echo)
        e, d = aecmos(bench, "st", lpb, echo, y)
        rows.append(dict(session=c["session"], talk="st", mos_echo_raw=e_raw, mos_echo=e, mos_deg=d,
                         erle=erle(echo, y), erle_hi=erle(echo, y, 8000)))
        mic, lpb = p("doubletalk_mic"), p("doubletalk_lpb")
        n = min(len(mic), len(lpb))
        mic, lpb = mic[:n], lpb[:n]
        y = clean(binary, mic, lpb)
        er, dr = aecmos(bench, "dt", lpb, mic, mic)
        e, d = aecmos(bench, "dt", lpb, mic, y)
        rows.append(dict(session=c["session"], talk="dt", mos_echo_raw=er, mos_deg_raw=dr, mos_echo=e, mos_deg=d))
        print(json.dumps(rows[-2]), json.dumps(rows[-1]), flush=True)
    json.dump(rows, open(bench / f"rfb/results_{label}.json", "w"), indent=1)
    m = lambda talk, key: np.nanmean([r[key] for r in rows if r["talk"] == talk])
    print(f"{label} real-fb | ST echo {m('st','mos_echo'):.2f} (raw {m('st','mos_echo_raw'):.2f}) "
          f"ERLE {m('st','erle'):.1f} hi {m('st','erle_hi'):.1f} | DT echo {m('dt','mos_echo'):.2f} "
          f"(raw {m('dt','mos_echo_raw'):.2f}) deg {m('dt','mos_deg'):.2f} (raw {m('dt','mos_deg_raw'):.2f})")


if __name__ == "__main__":
    main()
