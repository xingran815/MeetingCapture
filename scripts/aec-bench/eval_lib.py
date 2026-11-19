"""Shared scoring for the AEC-Challenge bench. See eval.py for what each score means."""
import json
from functools import lru_cache
from pathlib import Path

import numpy as np
import soundfile as sf

SR = 16000


def load(p):
    x, sr = sf.read(p, dtype="float64")
    assert sr == SR and x.ndim == 1, p
    return x


_mos = {}


def aecmos(bench):
    # Same features and inputs as the challenge's aecmos.py (v4, 16 kHz), without its torch import.
    if bench in _mos:
        return _mos[bench]
    import librosa
    import onnxruntime as ort
    sess = ort.InferenceSession(str(Path(bench) / "aecmos/Run_1663915512_Stage_0.onnx"))

    def mel(x):
        m = librosa.feature.melspectrogram(y=x, sr=SR, n_fft=513, hop_length=256, n_mels=160)
        return ((librosa.power_to_db(m, ref=np.max) + 40) / 40).T

    def run(talk, lpb, mic, enh):
        n = min(len(lpb), len(mic), len(enh), 20 * SR)
        f = [mel(s[:n].astype(np.float32)) for s in (lpb, mic, enh)]
        ne, fe = (1, 0) if talk == "nst" else (0, 1) if talk == "st" else (0, 0)
        pad = lambda s, v: np.concatenate((s, np.ones((20, s.shape[1])) * v, np.zeros((20, s.shape[1]))))
        feats = np.stack((pad(f[0], 1 - ne), pad(f[1], 1 - fe), pad(f[2], 1))).astype(np.float32)[None]
        r = sess.run([], {sess.get_inputs()[0].name: feats, "h0": np.zeros((4, 1, 64), np.float32)})[0]
        return float(r[0]), float(r[1])
    _mos[bench] = run
    return run


def cases(bench, split=None):
    """(name, split, kind, talk, scenario, mic, lpb, near or None) for each scored case."""
    bench = Path(bench)
    d = bench / "data/clips"
    for c in json.load(open(bench / "clips.json")):
        if split and c["split"] != split:
            continue
        lpb = load(d / f"{c['id']}_lpb.wav")
        if c["kind"] == "real":
            talk = "st" if c["scenario"].startswith("farend") else "dt"
            todo = [(c["id"], talk, load(d / f"{c['id']}_mic.wav"), None, c["scenario"])]
        else:
            sc = f"ser {c['ser']} dB, nonlinear {c['nonlinear']}"
            todo = [(c["id"] + "-st", "st", load(d / f"{c['id']}_echo.wav"), None, sc),
                    (c["id"] + "-dt", "dt", load(d / f"{c['id']}_mic.wav"), load(d / f"{c['id']}_near.wav"), sc)]
        for name, talk, mic, near, sc in todo:
            n = min(len(mic), len(lpb))
            yield name, c["split"], c["kind"], talk, sc, mic[:n], lpb[:n], (near[:n] if near is not None else None)


def erle(mic, out):
    return 10 * np.log10(np.sum(mic ** 2) / max(np.sum(out ** 2), 1e-20))


@lru_cache(maxsize=None)
def _raw_scores(bench, name, talk):
    return None


def score_all(bench, split, process, verbose=False):
    """process(name, mic, lpb) -> (output at 16 kHz, note) or output."""
    from pesq import pesq
    mos = aecmos(str(bench))
    rows = []
    for name, sp, kind, talk, sc, mic, lpb, near in cases(bench, split):
        r = process(name, mic, lpb)
        out, note = r if isinstance(r, tuple) else (r, "")
        row = {"case": name, "split": sp, "kind": kind, "talk": talk, "scenario": sc, "note": note}
        row["mos_echo_raw"], row["mos_deg_raw"] = mos(talk, lpb, mic, mic)
        row["mos_echo"], row["mos_deg"] = mos(talk, lpb, mic, out)
        if talk == "st":
            row["erle_db"] = erle(mic, out)
        if near is not None:
            row["pesq_raw"] = pesq(SR, near, mic, "wb")
            row["pesq"] = pesq(SR, near, out, "wb")
        rows.append(row)
        if verbose:
            print(json.dumps(row, default=lambda v: round(float(v), 2)), flush=True)
    return rows


GROUPS = [("real", "st"), ("real", "dt"), ("synthetic", "st"), ("synthetic", "dt")]


def summary(rows, label):
    parts = []
    for kind, talk in GROUPS:
        s = [x for x in rows if x["kind"] == kind and x["talk"] == talk]
        if not s:
            continue
        m = lambda k: np.mean([x[k] for x in s])
        txt = f"{kind[:4]}-{talk} echo {m('mos_echo'):.2f} deg {m('mos_deg'):.2f}"
        if talk == "dt":
            txt += f" (raw {m('mos_deg_raw'):.2f})"
        if talk == "st":
            txt += f" ERLE {m('erle_db'):.1f}"
        if kind == "synthetic" and talk == "dt":
            txt += f" PESQ {m('pesq'):.2f}"
        parts.append(txt)
    print(f"{label:14s} | " + " | ".join(parts), flush=True)
