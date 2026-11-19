#!/usr/bin/env python3
"""Residual-suppressor lab: tries suppressors on EchoRemover's linear stage (dumped by eval.py
with MEETINGCAPTURE_AEC_LINEAR_DIR) and scores them the way eval.py does.
Usage: res_lab.py <bench dir> <method>[,<method>...] [dev|test]
"""
import json, sys
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

BENCH = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("dev/tmp/aec-challenge")
WORK = BENCH / "work"
N, HOP = 1024, 512
WIN = np.sqrt(0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N) / N))


def stft(x):
    x = np.concatenate([x, np.zeros(N)])
    frames = [np.fft.rfft(x[i:i + N] * WIN) for i in range(0, len(x) - N + 1, HOP)]
    return np.array(frames)


def istft(S, n):
    out = np.zeros(len(S) * HOP + N)
    for t, s in enumerate(S):
        out[t * HOP:t * HOP + N] += np.fft.irfft(s, N) * WIN
    return out[:n]


def shipped(E, D, p=None):
    """The current ResidualSuppressor, frame by frame."""
    os_, floor = 16.0, 10 ** (-50 / 20)
    K = E.shape[1]
    cr = np.zeros(K); ci = np.zeros(K); es = np.zeros(K); ds = np.zeros(K); ef = np.zeros(K); tail = np.zeros(K)
    G = np.ones(E.shape)
    for t in range(len(E)):
        e, d = E[t], D[t]
        pe, pd = np.abs(e) ** 2, np.abs(d) ** 2
        x = e * np.conj(d)
        cr = 0.9 * cr + 0.1 * x.real; ci = 0.9 * ci + 0.1 * x.imag
        es = 0.9 * es + 0.1 * pe; ds = 0.9 * ds + 0.1 * pd; ef = 0.5 * ef + 0.5 * pe
        tail = np.maximum(pd, tail * 0.6)
        cross = cr ** 2 + ci ** 2
        coh = cross / (es * ds + 1e-20)
        leak = np.minimum(cross / (ds * ds + 1e-20), 1)
        res = os_ * leak * tail * np.minimum(coh * 4, 1)
        G[t] = np.maximum(1 - res / (ef + 1e-20), floor)
    return G


def none(E, D, p=None):
    return np.ones(E.shape)


def beta_res(E, D, os_=2.0, floor_db=-40, decay=0.6, smear=2, pct=25, rel=0.5):
    """Residual = beta(k) * echo-estimate power, beta from this file's echo-dominated frames."""
    PE, PD = np.abs(E) ** 2, np.abs(D) ** 2
    T, K = PE.shape
    beta = np.full(K, 1e-2)
    for k in range(K):
        d = PD[:, k]
        strong = d > np.percentile(d, 70)
        if strong.sum() >= 10 and d[strong].mean() > 1e-12:
            beta[k] = np.percentile(PE[strong, k] / (d[strong] + 1e-20), pct)
    beta = np.clip(beta, 1e-4, 1.0)
    tail = np.zeros(K); g_prev = np.ones(K); ef = np.zeros(K)
    G = np.ones((T, K)); floor = 10 ** (floor_db / 20)
    for t in range(T):
        tail = np.maximum(PD[t], tail * decay)
        r = beta * tail
        if smear:
            r = np.max([np.roll(r, i) for i in range(-smear, smear + 1)], axis=0)
        ef = 0.5 * ef + 0.5 * PE[t]
        g = np.maximum(1 - os_ * r / (ef + 1e-20), floor)
        g = np.where(g < g_prev, g, rel * g_prev + (1 - rel) * g)
        G[t] = g_prev = g
    return G


def gate_res(E, D, pct=50, os_=1.0, theta=1.0, hang=6, floor_db=-60, smear=2, decay=0.6, rel=0.5, os2=2.0):
    """beta residual + a frame gate: a frame with nothing left beyond echo and noise is muted."""
    PE, PD = np.abs(E) ** 2, np.abs(D) ** 2
    T, K = PE.shape
    beta = np.full(K, 1e-2)
    for k in range(K):
        d = PD[:, k]
        strong = d > np.percentile(d, 70)
        if strong.sum() >= 10 and d[strong].mean() > 1e-12:
            beta[k] = np.percentile(PE[strong, k] / (d[strong] + 1e-20), pct)
    beta = np.clip(beta, 1e-4, 4.0)
    noise = np.percentile(PE, 10, axis=0) + 1e-14
    band = slice(7, 86)
    tail = np.zeros(K); g_prev = np.ones(K); ef = np.zeros(K); held = 0
    G = np.ones((T, K)); floor = 10 ** (floor_db / 20)
    for t in range(T):
        tail = np.maximum(PD[t], tail * decay)
        r = beta * tail
        if smear:
            r = np.max([np.roll(r, i) for i in range(-smear, smear + 1)], axis=0)
        ef = 0.5 * ef + 0.5 * PE[t]
        g = np.maximum(1 - os_ * r / (ef + 1e-20), floor)
        left = np.maximum(PE[t, band] - os2 * r[band] - 2 * noise[band], 0).sum()
        echoish = r[band].sum() > noise[band].sum()
        if left > theta * (r[band].sum() + noise[band].sum()) or not echoish:
            held = hang
        elif held > 0:
            held -= 1
        if held == 0:
            g = np.full(K, floor)
        g = np.where(g < g_prev, g, rel * g_prev + (1 - rel) * g)
        G[t] = g_prev = g
    return G


def soft_res(E, D, pct=50, os_=1.0, c_db=0.0, slope=0.5, release=0.8, frame_floor_db=-40, floor_db=-40,
             smear=2, decay=0.6, rel=0.5, ahead=0):
    """beta residual per bin, times a soft near-end presence per frame: frames with nothing left
    beyond echo and noise fade down to frame_floor; frames with near-end speech keep the bin gain."""
    PE, PD = np.abs(E) ** 2, np.abs(D) ** 2
    T, K = PE.shape
    beta = np.full(K, 1e-2)
    for k in range(K):
        d = PD[:, k]
        strong = d > np.percentile(d, 70)
        if strong.sum() >= 10 and d[strong].mean() > 1e-12:
            beta[k] = np.percentile(PE[strong, k] / (d[strong] + 1e-20), pct)
    beta = np.clip(beta, 1e-4, 4.0)
    noise = np.percentile(PE, 10, axis=0) + 1e-14
    band = slice(7, 86)
    T_ = T
    tail = np.zeros(K); ef = np.zeros(K)
    gb = np.ones((T, K)); praw = np.ones(T)
    floor = 10 ** (floor_db / 20); ff = 10 ** (frame_floor_db / 20)
    for t in range(T):
        tail = np.maximum(PD[t], tail * decay)
        r = beta * tail
        if smear:
            r = np.max([np.roll(r, i) for i in range(-smear, smear + 1)], axis=0)
        ef = 0.5 * ef + 0.5 * PE[t]
        gb[t] = np.maximum(1 - os_ * r / (ef + 1e-20), floor)
        rs, ns = r[band].sum(), noise[band].sum()
        left = np.maximum(PE[t, band] - r[band] - noise[band], 0).sum()
        if rs < ns:
            praw[t] = 1.0
        else:
            snr = 10 * np.log10(left / (rs + ns) + 1e-6)
            praw[t] = 1 / (1 + np.exp(-slope * (snr - c_db)))
    a = int(ahead)
    if a:
        praw = np.array([praw[t:t + a + 1].max() for t in range(T)])
    G = np.ones((T, K)); g_prev = np.ones(K); presence = 1.0
    for t in range(T):
        p = praw[t]
        presence = p if p > presence else release * presence + (1 - release) * p
        g = gb[t] * (ff + (1 - ff) * presence)
        g = np.where(g < g_prev, g, rel * g_prev + (1 - rel) * g)
        G[t] = g_prev = g
    return G


METHODS = {"shipped": shipped, "linear": none}


def nn_res(E, D, weights=None, hi="edge"):
    """The neural mask on 0-8 kHz; above that, the mask's top bins carried on."""
    import nres
    weights = weights or str(BENCH / "nres.pt")
    lg = lambda X: np.log(np.abs(X[:, :nres.BINS]) ** 2 + 1e-10)
    m = nres.mask_for(lg(E), lg(D), weights)
    G = np.empty(E.shape)
    G[:, :nres.BINS] = m
    G[:, nres.BINS:] = m[:, -20:].mean(axis=1, keepdims=True)
    return G


VOICE_SAFE = dict(pct=45.61, os_=1.6, c_db=-1.62, slope=0.95, release=0.96, frame_floor_db=-21.27,
                  floor_db=-22.31, decay=0.68, ahead=4)


def blend(E, D, how, a=0.5):
    n, c = nn_res(E, D), soft_res(E, D, **VOICE_SAFE)
    if how == "max":
        return np.maximum(n, c)
    if how == "min":
        return np.minimum(n, c)
    return n ** a * c ** (1 - a)


def soft_from(name):
    if name.startswith("blend"):
        parts = name.split(":")
        return lambda E, D, p=None: blend(E, D, parts[1], float(parts[2]) if len(parts) > 2 else 0.5)
    if name.startswith("nn"):
        w = name.split(":", 1)[1] if ":" in name else None
        return lambda E, D, p=None: nn_res(E, D, w)
    # name like soft:pct=50,os_=1,...
    kw = dict(kv.split("=") for kv in name.split(":", 1)[1].split(",")) if ":" in name else {}
    kw = {k: float(v) for k, v in kw.items()}
    return lambda E, D, p=None: soft_res(E, D, **kw)


def load_case(name):
    e, _ = sf.read(WORK / f"{name}_out48_linear_error.wav", dtype="float64")
    d, _ = sf.read(WORK / f"{name}_out48_linear_estimate.wav", dtype="float64")
    return e, d


_spectra = {}


def comfort(E, G, level=1.0, seed=0):
    """Fills what the gains took away back up to the steady room noise, so the floor doesn't
    pump with the far side. Noise per bin: the 10th percentile of the error's power."""
    noise = np.percentile(np.abs(E) ** 2, 10, axis=0) * level
    missing = np.maximum(noise[None, :] - (G ** 2) * noise[None, :], 0)
    rng = np.random.default_rng(seed)
    phase = np.exp(2j * np.pi * rng.random(E.shape))
    return E * G + np.sqrt(missing) * phase


def run(method, name, mic16):
    if not (WORK / f"{name}_out48_linear_error.wav").exists():
        return mic16.copy()  # EchoRemover found no echo, so the user gets the raw mic
    if name not in _spectra:
        e, d = load_case(name)
        _spectra[name] = (len(e), stft(e), stft(d))
    n, E, D = _spectra[name]
    cn = method.endswith("+cn")
    m = method[:-3] if cn else method
    fn = METHODS[m] if m in METHODS else soft_from(m)
    G = fn(E, D)
    y = istft(comfort(E, G) if cn else E * G, n)
    y16 = resample_poly(y, 1, 3)[:len(mic16)]
    return np.pad(y16, (0, len(mic16) - len(y16)))


if __name__ == "__main__":
    sys.path.insert(0, str(Path(__file__).parent))
    import eval_lib as ev
    split = sys.argv[3] if len(sys.argv) > 3 else "dev"
    for m in sys.argv[2].split(";"):
        rows = ev.score_all(BENCH, split, lambda name, mic, lpb: run(m, name, mic))
        ev.summary(rows, m)
