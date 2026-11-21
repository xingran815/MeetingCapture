#!/usr/bin/env python3
"""Full-band (48 kHz) clips from the challenge's synthetic_fullband set (issue 31), read one file
at a time out of the 26 GB zip with HTTP range requests, so nothing near its size is
downloaded or stored.

  fb_data.py <bench> <binary> <n_train>

Seed 20261120 shuffles the 10,000 file ids: the first 6 are dev and the next 10 test (their
wavs are kept in <bench>/fb/clips, listed in <bench>/fb/clips.json), the next n_train are
training data. A training clip goes through the binary's linear stage, and only its features
are kept, all 513 bins of the 1024-point STFT: log|E|^2, log|D|^2 and |S| (the near end the
output should keep, zero for echo-only clips), float16. A quarter are also used echo only.
"""
import csv, io, json, os, random, subprocess, sys, tempfile, threading, urllib.request, zipfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import numpy as np
import soundfile as sf

ZIP = ("https://crowdsourcedatapub.blob.core.windows.net/crowdsource-data/"
       "aec_challenge_data_downloads/icassp2022/fullband_synthetic.zip")
N, HOP = 1024, 512
WIN = np.sqrt(0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N) / N))


class HTTPFile(io.RawIOBase):
    """A seekable read-only file over HTTP range requests."""

    def __init__(self, url):
        self.url, self.pos = url, 0
        head = urllib.request.urlopen(urllib.request.Request(url, method="HEAD"), timeout=60)
        self.size = int(head.headers["Content-Length"])

    def seekable(self):
        return True

    def readable(self):
        return True

    def tell(self):
        return self.pos

    def seek(self, offset, whence=0):
        self.pos = offset if whence == 0 else self.pos + offset if whence == 1 else self.size + offset
        return self.pos

    def readinto(self, b):
        if self.pos >= self.size or len(b) == 0:
            return 0
        end = min(self.pos + len(b), self.size) - 1
        req = urllib.request.Request(self.url, headers={"Range": f"bytes={self.pos}-{end}"})
        for attempt in range(4):
            try:
                data = urllib.request.urlopen(req, timeout=120).read()
                break
            except OSError:
                if attempt == 3:
                    raise
        b[:len(data)] = data
        self.pos += len(data)
        return len(data)


_local = threading.local()


def archive():
    if not hasattr(_local, "zip"):
        _local.zip = zipfile.ZipFile(io.BufferedReader(HTTPFile(ZIP), buffer_size=1 << 20))
    return _local.zip


def read(fid, kind):
    """One wav from the zip, as float64 at 48 kHz."""
    x, sr = sf.read(io.BytesIO(archive().read(f"data/{fid}_{kind}.wav")), dtype="float64")
    assert sr == 48000, (fid, kind, sr)
    return x if x.ndim == 1 else x[:, 0]


def spec(x):
    x = np.concatenate([x, np.zeros(N)])
    return np.array([np.fft.rfft(x[i:i + N] * WIN) for i in range(0, len(x) - N + 1, HOP)])


def linear_stage(binary, mic, lpb):
    with tempfile.TemporaryDirectory(dir=WORK) as d:
        d = Path(d)
        n = min(len(mic), len(lpb))
        sf.write(d / "in.wav", np.clip(np.stack([mic[:n], lpb[:n]], 1), -1, 1), 48000, subtype="PCM_16")
        env = dict(os.environ, MEETINGCAPTURE_E2E="1", MEETINGCAPTURE_AEC_LINEAR_DIR=str(d))
        subprocess.run([binary, "--clean-echo", str(d / "in.wav"), "--clean-echo-out", str(d / "out.wav")],
                       check=True, capture_output=True, env=env, timeout=300)
        if not (d / "out_linear_error.wav").exists():
            return None
        e, _ = sf.read(d / "out_linear_error.wav", dtype="float64")
        dd, _ = sf.read(d / "out_linear_estimate.wav", dtype="float64")
        return e, dd


def save(binary, name, mic, lpb, near):
    out = FEAT / f"{name}.npz"
    if out.exists():
        return "cached"
    r = linear_stage(binary, mic, lpb)
    if r is None:
        return "no-echo"
    e, d = r
    s = np.pad(near, (0, max(len(e) - len(near), 0)))[:len(e)]
    E, D, S = spec(e), spec(d), spec(s)
    lg = lambda X: np.log(np.abs(X) ** 2 + 1e-10).astype(np.float16)
    np.savez(out, le=lg(E), ld=lg(D), s=np.abs(S).astype(np.float16))
    return "ok"


def train_job(binary, fid, k):
    mic, lpb, echo, near = (read(fid, kind) for kind in ("mic", "farend", "echo", "nearend"))
    out = [save(binary, f"{fid}-dt", mic, lpb, near)]
    if k % 4 == 0:
        out.append(save(binary, f"{fid}-st", echo, lpb, np.zeros_like(echo)))
    return out


def bench_job(fid, split, meta):
    for kind in ("mic", "farend", "echo", "nearend"):
        p = CLIPS / f"{fid}_{kind}.wav"
        if not p.exists():
            sf.write(p, read(fid, kind), 48000, subtype="PCM_16")
    m = meta.get(fid, {})
    return {"fid": fid, "split": split, "ser": round(float(m.get("ser", "nan")), 1),
            "delay_ms": round(float(m.get("echo_delay", "nan")), 1),
            "noisy": m.get("is_nearend_noisy") == "True" or m.get("is_farend_noisy") == "True"}


if __name__ == "__main__":
    BENCH, BIN, N_TRAIN = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    FB = BENCH / "fb"
    CLIPS, FEAT, WORK = FB / "clips", FB / "feat", FB / "work"
    for d in (CLIPS, FEAT, WORK):
        d.mkdir(parents=True, exist_ok=True)
    meta = {r["file_id"]: r for r in csv.DictReader(open(BENCH / "data/meta_fullband.csv"))}
    ids = sorted(meta)
    random.Random(20261120).shuffle(ids)
    dev, test, train = ids[:6], ids[6:16], ids[16:16 + N_TRAIN]
    clips = [bench_job(f, "dev", meta) for f in dev] + [bench_job(f, "test", meta) for f in test]
    json.dump(clips, open(FB / "clips.json", "w"), indent=1)
    print("bench clips:", len(clips), flush=True)

    counts = {}

    def safe(job):
        try:
            return train_job(BIN, *job)
        except Exception as error:  # one bad clip mustn't stop the run
            print("skipped:", job[0], type(error).__name__, error, flush=True)
            return ["failed"]

    with ThreadPoolExecutor(2) as ex:  # two at a time: low memory (user's rule)
        for k, res in enumerate(ex.map(safe, [(f, k) for k, f in enumerate(train)])):
            for r in res:
                counts[r] = counts.get(r, 0) + 1
            if k % 50 == 0:
                print(k, len(train), counts, flush=True)
    print("done", counts, flush=True)
