#!/usr/bin/env python3
"""Training data for a neural residual-echo suppressor, kept apart from the 16 bench clips:
synthetic clips from the challenge's `train` split, and real far-end single talk mixed with
real near-end single talk from other devices (none of the bench GUIDs).

Each clip goes through the built EchoRemover (its linear stage is dumped), and what is kept
per clip is only the model's input and target at 48 kHz STFT bins 0-170 (0-8 kHz):
log|E| (linear-stage error), log|D| (echo estimate), |S| (the near-end the output should keep,
zero for echo-only clips), |E|, as float16. Usage: train_data.py <bench> <binary> <n_syn> <n_real>
"""
import csv, json, os, random, re, subprocess, sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

BENCH, BIN = Path(sys.argv[1]), sys.argv[2]
N_SYN, N_REAL = int(sys.argv[3]), int(sys.argv[4])
RAW, FEAT, WORK = BENCH / "train/raw", BENCH / "train/feat", BENCH / "train/work"
for d in (RAW, FEAT, WORK):
    d.mkdir(parents=True, exist_ok=True)
URL = "https://github.com/microsoft/AEC-Challenge/raw/main/datasets/"
N, HOP, BINS = 1024, 512, 171
WIN = np.sqrt(0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N) / N))
rng = random.Random(7)

bench = json.load(open(BENCH / "clips.json"))
banned = {c["guid"] for c in bench if c["kind"] == "real"}
syn_rows = [r for r in csv.DictReader(open(BENCH / "data/meta.csv")) if r["split"] == "train"]
rng.shuffle(syn_rows)
files = [l.strip()[len("datasets/real/"):] for l in open(BENCH / "real_list.txt") if l.startswith("datasets/real/")]
by = {}
for f in files:
    m = re.match(r"(.+?)_(farend_singletalk|nearend_singletalk)_(lpb|mic)\.wav$", f)
    if m and m.group(1) not in banned:
        by.setdefault(m.group(2), set()).add(m.group(1))
fe = sorted(g for g in by["farend_singletalk"])
ne = sorted(by["nearend_singletalk"])
rng.shuffle(fe); rng.shuffle(ne)


def fetch(rel, name):
    out = RAW / name
    if not out.exists():
        from urllib.parse import quote
        subprocess.run(["curl", "-sSfL", "-o", str(out), URL + quote(rel)], check=True)
    return out


def load16(p):
    x, sr = sf.read(p, dtype="float64")
    assert sr == 16000, p
    return x if x.ndim == 1 else x[:, 0]


def spec(x):
    x = np.concatenate([x, np.zeros(N)])
    return np.array([np.fft.rfft(x[i:i + N] * WIN)[:BINS] for i in range(0, len(x) - N + 1, HOP)])


def linear_stage(name, mic, lpb):
    n = min(len(mic), len(lpb))
    st = np.stack([resample_poly(mic[:n], 3, 1), resample_poly(lpb[:n], 3, 1)], axis=1)
    inp, out = WORK / f"{name}_in.wav", WORK / f"{name}.wav"
    sf.write(inp, np.clip(st, -1, 1), 48000, subtype="PCM_16")
    env = dict(os.environ, MEETINGCAPTURE_E2E="1", MEETINGCAPTURE_AEC_LINEAR_DIR=str(WORK))
    subprocess.run([BIN, "--clean-echo", str(inp), "--clean-echo-out", str(out)], check=True,
                   capture_output=True, env=env, timeout=300)
    ep, dp = WORK / f"{name}_linear_error.wav", WORK / f"{name}_linear_estimate.wav"
    res = None
    if ep.exists():
        e, _ = sf.read(ep, dtype="float64"); d, _ = sf.read(dp, dtype="float64")
        res = (e, d)
    for p in (inp, out, ep, dp):
        p.unlink(missing_ok=True)
    return res


def save(name, mic, lpb, near):
    if (FEAT / f"{name}.npz").exists():
        return "cached"
    r = linear_stage(name, mic, lpb)
    if r is None:
        return "no-echo"
    e, d = r
    s = resample_poly(near, 3, 1)[:len(e)]
    s = np.pad(s, (0, len(e) - len(s)))
    E, D, S = spec(e), spec(d), spec(s)
    lg = lambda X: np.log(np.abs(X) ** 2 + 1e-10).astype(np.float16)
    np.savez(FEAT / f"{name}.npz", le=lg(E), ld=lg(D), s=np.abs(S).astype(np.float16), e=np.abs(E).astype(np.float16))
    return "ok"


def syn_job(r):
    f = r["fileid"]
    p = {k: fetch(f"synthetic/{d}/{pre}_fileid_{f}.wav", f"syn{f}_{k}.wav") for k, d, pre in
         [("lpb", "farend_speech", "farend_speech"), ("mic", "nearend_mic_signal", "nearend_mic"),
          ("echo", "echo_signal", "echo"), ("near", "nearend_speech", "nearend_speech")]}
    lpb, mic, echo, near = (load16(p[k]) for k in ("lpb", "mic", "echo", "near"))
    out = [save(f"syn{f}-dt", mic, lpb, near)]
    if int(f) % 4 == 0:  # a quarter also as echo only: the output should be silence
        out.append(save(f"syn{f}-st", echo, lpb, np.zeros_like(echo)))
    for k in p.values():
        k.unlink()
    return out


def real_job(i):
    g, h = fe[i], ne[i]
    mic_p = fetch(f"real/{g}_farend_singletalk_mic.wav", f"r{g}_mic.wav")
    lpb_p = fetch(f"real/{g}_farend_singletalk_lpb.wav", f"r{g}_lpb.wav")
    nst_p = fetch(f"real/{h}_nearend_singletalk_mic.wav", f"r{h}_nst.wav")
    mic, lpb, near = load16(mic_p), load16(lpb_p), load16(nst_p)
    n = min(len(mic), len(lpb), len(near))
    mic, lpb, near = mic[:n], lpb[:n], near[:n]
    out = []
    if i % 3 == 0:  # echo only
        out.append(save(f"real{i}-st", mic, lpb, np.zeros(n)))
    else:  # near end over the echo at -5..+10 dB, by mean power
        ser = rng.uniform(-5, 10)
        gain = np.sqrt(np.mean(mic ** 2) / (np.mean(near ** 2) + 1e-12) / 10 ** (ser / 10))
        out.append(save(f"real{i}-dt", mic + gain * near, lpb, gain * near))
    for k in (mic_p, lpb_p, nst_p):
        k.unlink()
    return out


jobs = [(syn_job, r) for r in syn_rows[:N_SYN]] + [(real_job, i) for i in range(N_REAL)]
counts = {}
with ThreadPoolExecutor(2) as ex:  # two at a time: low memory (user's rule)
    def safe(j):
        try:
            return j[0](j[1])
        except Exception as error:  # one bad clip mustn't stop the run
            print("skipped:", type(error).__name__, flush=True)
            return ["failed"]

    for k, res in enumerate(ex.map(safe, jobs)):
        for x in res:
            counts[x] = counts.get(x, 0) + 1
        if k % 50 == 0:
            print(k, len(jobs), counts, flush=True)
print("done", counts, flush=True)
