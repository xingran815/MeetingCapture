#!/usr/bin/env python3
"""Real full-band (48 kHz) training data from the challenge's fullband.zip (issue 31): real PC
calls, read one file at a time with HTTP range requests (fb_data.HTTPFile).

  real_data.py <bench> <binary>

Every file in the archive is 48 kHz, but many devices cut off above 8 kHz. A track is used
only if it really carries sound up there: in 8-24 kHz its loud frames (70th percentile of
frame energy) must be at least HI_MIN_DB over its quiet frames (15th percentile). Cut-off
tracks are never trained on. Each session's keep or skip, with its numbers, goes to
<bench>/rfb/filter.jsonl.

A session gives:
  - double talk: its echo-only recording (farend-singletalk mic) plus its voice-only
    recording (nearend-singletalk mic, same device and room) mixed at a random
    signal-to-echo ratio in [-10, 10] dB; the voice-only recording is the target. Needs the
    reference, the echo and the voice all to pass.
  - echo only: the echo-only recording, target silence. Needs the reference and the echo
    to pass.
Seed 20261121 shuffles the sessions; the first TEST that pass on their real double-talk
recording are kept whole in <bench>/rfb/clips as a real full-band test (never trained on).
Features go to <bench>/rfb/feat, as fb_data.py writes them (513 bins, float16).
"""
import io, json, random, re, sys, threading, zipfile
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import stft

sys.path.insert(0, str(Path(__file__).resolve().parent))
import fb_data  # noqa: E402

ZIP = ("https://crowdsourcedatapub.blob.core.windows.net/crowdsource-data/"
       "aec_challenge_data_downloads/icassp2022/fullband.zip")
SR, HI_MIN_DB, TEST = 48000, 10.0, 10
_local = threading.local()


def archive():
    if not hasattr(_local, "zip"):
        _local.zip = zipfile.ZipFile(io.BufferedReader(fb_data.HTTPFile(ZIP), buffer_size=1 << 20))
    return _local.zip


def read(session, kind):
    x, sr = sf.read(io.BytesIO(fb_data.member(archive(), f"fullband/{fb_data.safe_id(session)}_{kind}.wav")),
                    dtype="float64")
    if sr != SR:
        raise ValueError(f"{kind} is {sr} Hz")
    return x if x.ndim == 1 else x[:, 0]


def hi_over_noise(x):
    """dB of 8-24 kHz energy in loud frames over quiet frames: near 0 means cut off."""
    f, _, X = stft(x, SR, nperseg=1024)
    P = np.abs(X) ** 2
    e = P.sum(0)
    hi = P[f >= 8000]
    loud, quiet = e > np.percentile(e, 70), e < np.percentile(e, 15)
    if loud.sum() < 10 or quiet.sum() < 10:
        return float("nan")
    return float(10 * np.log10(hi[:, loud].sum(0).mean() / (hi[:, quiet].sum(0).mean() + 1e-20) + 1e-20))


def passes(db):
    return bool(np.isfinite(db) and db >= HI_MIN_DB)


def features(name, mic, lpb, target):
    out = FEAT / f"{name}.npz"
    if out.exists():
        return "cached"
    r = fb_data.linear_stage(BIN, mic, lpb)
    if r is None:
        return "no-echo"
    e, d = r
    s = np.pad(target, (0, max(len(e) - len(target), 0)))[:len(e)]
    lg = lambda X: np.log(np.abs(X) ** 2 + 1e-10).astype(np.float16)
    np.savez(out, le=lg(fb_data.spec(e)), ld=lg(fb_data.spec(d)), s=np.abs(fb_data.spec(s)).astype(np.float16))
    return "ok"


def train_job(session, k):
    log = {"session": session}
    lpb, echo = read(session, "farend-singletalk_lpb"), read(session, "farend-singletalk_mic")
    log["lpb_db"], log["echo_db"] = round(hi_over_noise(lpb), 1), round(hi_over_noise(echo), 1)
    out = []
    if not (passes(log["lpb_db"]) and passes(log["echo_db"])):
        log["kept"] = "none: reference or echo cut off"
        return log, ["cut-off"]
    n = min(len(lpb), len(echo))
    lpb, echo = lpb[:n], echo[:n]
    out.append(features(f"{session}-st", echo, lpb, np.zeros(n)))
    voice = read(session, "nearend-singletalk_mic")
    log["voice_db"] = round(hi_over_noise(voice), 1)
    if passes(log["voice_db"]):
        m = min(n, len(voice))
        ser = random.Random(f"{session}{k}").uniform(-10, 10)
        pe, pv = np.mean(echo[:m] ** 2) + 1e-12, np.mean(voice[:m] ** 2) + 1e-12
        v = voice[:m] * np.sqrt(pe / pv * 10 ** (ser / 10))
        mic = echo[:m] + v
        peak = np.abs(mic).max()
        if peak > 0.99:  # keep the mix and its target at the same scale
            mic, v = mic * 0.99 / peak, v * 0.99 / peak
        log["ser_db"] = round(ser, 1)
        out.append(features(f"{session}-dt", mic, lpb[:m], v))
        log["kept"] = "double talk and echo only"
    else:
        log["kept"] = "echo only: voice cut off"
    return log, out


def test_job(session):
    """A test session: its real double-talk recording and its echo-only one, both must pass."""
    kinds = ("doubletalk_mic", "doubletalk_lpb", "farend-singletalk_mic", "farend-singletalk_lpb")
    x = {k: read(session, k) for k in kinds}
    dbs = {k: round(hi_over_noise(v), 1) for k, v in x.items()}
    if not all(passes(v) for v in dbs.values()):
        return None, dbs
    for k, v in x.items():
        sf.write(CLIPS / f"{session}_{k}.wav", v, SR, subtype="PCM_16")
    return {"session": session, **{f"{k}_db": v for k, v in dbs.items()}}, dbs


if __name__ == "__main__":
    BENCH, BIN = Path(sys.argv[1]), sys.argv[2]
    RFB = BENCH / "rfb"
    CLIPS, FEAT, fb_data.WORK = RFB / "clips", RFB / "feat", BENCH / "fb/work"
    for d in (CLIPS, FEAT, fb_data.WORK):
        d.mkdir(parents=True, exist_ok=True)
    kinds = defaultdict(set)
    for n in archive().namelist():
        m = re.match(r"fullband/([A-Za-z0-9_-]+)_([a-z-]+_(?:mic|lpb))\.wav$", n)  # no / or ..
        if m:
            kinds[m.group(1)].add(m.group(2))
    need = {"farend-singletalk_mic", "farend-singletalk_lpb", "nearend-singletalk_mic", "doubletalk_mic",
            "doubletalk_lpb"}
    sessions = sorted(s for s, k in kinds.items() if {"farend-singletalk_mic", "farend-singletalk_lpb"} <= k)
    random.Random(20261121).shuffle(sessions)
    print("sessions with an echo-only recording:", len(sessions), flush=True)

    test, tried = [], 0
    for s in sessions:
        if len(test) == TEST:
            break
        if not need <= kinds[s]:
            continue
        tried += 1
        row, dbs = test_job(s)
        if row:
            test.append(row)
    json.dump(test, open(RFB / "clips.json", "w"), indent=1)
    held = {r["session"] for r in test}
    print(f"test sessions: {len(test)} kept of {tried} tried", flush=True)

    train = [s for s in sessions if s not in held]
    counts = {}
    flog = open(RFB / "filter.jsonl", "a")

    def safe(job):
        try:
            return train_job(*job)
        except Exception as error:  # one bad session mustn't stop the run
            return {"session": job[0], "kept": f"failed: {type(error).__name__} {error}"}, ["failed"]

    with ThreadPoolExecutor(2) as ex:  # two at a time: low memory (user's rule)
        for k, (log, res) in enumerate(ex.map(safe, [(s, k) for k, s in enumerate(train)])):
            flog.write(json.dumps(log) + "\n")
            flog.flush()
            for r in res:
                counts[r] = counts.get(r, 0) + 1
            if k % 50 == 0:
                print(k, len(train), counts, flush=True)
    print("done", counts, flush=True)
