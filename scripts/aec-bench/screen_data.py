#!/usr/bin/env python3
"""Inputs for screen.py, the quick GPU check of a trained network (issue 31). Public challenge
clips only, never a user's recording, so the result can go to a training machine.

  screen_data.py <bench> <binary>

Runs the built binary's linear stage once per clip and saves what the network sees (log
powers of E and D, as nres.py trains on) plus which frames to measure, to <bench>/screen/:
  - fb-<fid>-dt: the full-band bench's double talk; frames where the near end talks alone
    (near loud, far quiet) measure voice loss
  - fb-<fid>-st: its echo alone; frames with the far end loud measure echo removed
  - rfb-<session>-st: the real full-band test's echo-only recording, same
  - rfb-<session>-voice: the same session's voice-only recording through the linear stage
    with its own (silent) reference: the user's case of talking while the far end is quiet;
    loud frames measure voice loss. Needs the voice track to pass real_data's 8 kHz check.
The binary is only run, never built, so this doesn't touch the source tree.
"""
import json, subprocess, sys
from pathlib import Path

import numpy as np
import soundfile as sf

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fb_data  # noqa: E402
import real_data  # noqa: E402

SILENT = float(np.log(1e-10))


def frame_power(x, n):
    p = (np.abs(fb_data.spec(x)) ** 2).sum(1)
    return np.pad(p, (0, max(n - len(p), 0)))[:n]


def save(out, name, mic, lpb, flags):
    if (out / f"{name}.npz").exists():
        return
    try:
        r = fb_data.linear_stage(BIN, mic, lpb)
    except subprocess.CalledProcessError:  # a silent reference: the binary won't run the linear stage
        r = None
    if r is None:  # no echo found: the network gets the mic as E and nothing as D
        E = fb_data.spec(mic)
        ld = np.full(E.shape, SILENT, np.float32)
    else:
        E, ld = fb_data.spec(r[0]), np.log(np.abs(fb_data.spec(r[1])) ** 2 + 1e-10)
    n = len(E)
    le = np.log(np.abs(E) ** 2 + 1e-10)
    m = {k: np.pad(v, (0, max(n - len(v), 0)))[:n] for k, v in flags(n).items()}
    np.savez(out / f"{name}.npz", le=le.astype(np.float16), ld=ld[:n].astype(np.float16), **m)
    print(name, n, {k: int(v.sum()) for k, v in m.items()}, flush=True)


if __name__ == "__main__":
    BENCH, BIN = Path(sys.argv[1]), sys.argv[2]
    fb_data.WORK = BENCH / "fb/work"
    out = BENCH / "screen"
    out.mkdir(exist_ok=True)
    for c in [c for c in json.load(open(BENCH / "fb/clips.json")) if c["split"] == "test"]:
        p = lambda k: sf.read(BENCH / f"fb/clips/{c['fid']}_{k}.wav", dtype="float64")[0]
        mic, lpb, echo, near = p("mic"), p("farend"), p("echo"), p("nearend")

        def dt(n):
            pn, pf = frame_power(near, n), frame_power(lpb, n)
            return {"voice": (pn > np.percentile(pn, 60)) & (pf < np.percentile(pf, 30))}

        def st(n):
            pf = frame_power(lpb, n)
            return {"echo": pf > np.percentile(pf, 50)}
        save(out, f"fb-{c['fid']}-dt", mic, lpb, dt)
        save(out, f"fb-{c['fid']}-st", echo, lpb, st)
    for c in json.load(open(BENCH / "rfb/clips.json")):
        s = c["session"]
        p = lambda k: sf.read(BENCH / f"rfb/clips/{s}_{k}.wav", dtype="float64")[0]
        echo, lpb = p("farend-singletalk_mic"), p("farend-singletalk_lpb")

        def st(n):
            pf = frame_power(lpb, n)
            return {"echo": pf > np.percentile(pf, 50)}
        save(out, f"rfb-{s}-st", echo, lpb, st)
        if (out / f"rfb-{s}-voice.npz").exists():
            continue
        voice = real_data.read(s, "nearend-singletalk_mic")
        try:
            vlpb = real_data.read(s, "nearend-singletalk_lpb")
        except KeyError:  # some sessions have no reference for their voice-only take: it is silent
            vlpb = np.zeros_like(voice)
        if not real_data.passes(real_data.hi_over_noise(voice)):
            print(f"rfb-{s}-voice skipped: voice cut off above 8 kHz", flush=True)
            continue

        def loud(n):
            pv = frame_power(voice, n)
            return {"voice": pv > np.percentile(pv, 50)}
        save(out, f"rfb-{s}-voice", voice, vlpb, loud)
