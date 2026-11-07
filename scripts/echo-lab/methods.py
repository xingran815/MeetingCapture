"""Candidate echo removers for the M3.2 lab. Each takes (mic, ref) and returns the
cleaned mic, the same length. Parameters are frozen by name in METHODS, so a figure can
always be traced to one configuration, and a reviewer can rerun it.
"""
import subprocess
import tempfile
from pathlib import Path

import numpy as np

import lab


def lag_track(mic, ref, win_s=20, hop_s=30, max_ms=400, min_ms=2):
    """[(centre seconds, lag samples)] from a whitened cross-correlation per window. Memory
    stays bounded by one window. Taps under `min_ms` are ignored: a false peak at exactly 0
    appears in some windows, and no speaker and mic pair has that little delay."""
    SR = lab.SR
    n = min(len(mic), len(ref))
    W, H = int(win_s * SR), int(hop_s * SR)
    nf = 2 ** int(np.ceil(np.log2(2 * W)))
    lo, hi = int(min_ms * SR / 1000), int(max_ms * SR / 1000)
    out = []
    for s in range(0, max(n - W, 1), H):
        m, r = mic[s : s + W].astype(np.float64), ref[s : s + W].astype(np.float64)
        if np.mean(r**2) < 1e-7:
            continue
        S = np.fft.rfft(m, nf) * np.fft.rfft(r, nf).conj()
        c = np.abs(np.fft.irfft(S / (np.abs(S) + 1e-9 * np.abs(S).max()), nf)[:hi])
        c[:lo] = 0
        k = int(np.argmax(c))
        # Only clear peaks: speech over speech gives a low, unreliable one.
        if c[k] > 15 * (np.median(c[lo:]) + 1e-12):
            out.append(((s + W / 2) / SR, k))
    return out


def global_lag(mic, ref):
    t = lag_track(mic, ref)
    return int(np.median([k for _, k in t])) if t else 0


def drift_ppm(mic, ref, track=None):
    """How much faster the mic's clock runs, from the robust slope of the lag over time."""
    t = lag_track(mic, ref) if track is None else track
    if len(t) < 6 or t[-1][0] - t[0][0] < 60:
        return 0.0  # Too short to see a drift, and too short for it to matter.
    a = np.array(t, dtype=np.float64)
    med = np.median(a[:, 1])
    a = a[np.abs(a[:, 1] - med) < 0.02 * lab.SR]  # Outliers beyond 20 ms.
    d = [(a[j, 1] - a[i, 1]) / (a[j, 0] - a[i, 0]) for i in range(len(a)) for j in range(i + 1, len(a))
         if a[j, 0] - a[i, 0] >= 60]
    return float(np.median(d) / lab.SR * 1e6) if d else 0.0


class PFDKF:
    """Partitioned-block frequency-domain Kalman filter, diagonal approximation.

    Step size comes from the state's uncertainty over the error's power, so when the
    user talks the error grows and the filter barely moves, with no separate double-talk
    detector. `freeze` skips adaptation on blocks a caller marks as near-end.
    """

    def __init__(self, m=1024, parts=24, a=0.9995, p0=1.0, nonlinear=False):
        self.m, self.parts, self.a2 = m, parts, a**2
        self.f = m + 1
        self.branches = 2 if nonlinear else 1
        self.nl = nonlinear
        count = parts * self.branches
        self.P = np.full((count, self.f), p0, dtype=np.float64)
        self.H = np.zeros((count, self.f), dtype=np.complex128)
        self.X = np.zeros((count, self.f), dtype=np.complex128)
        self.old = np.zeros(m)
        self.old_nl = np.zeros(m)

    def filt(self, x):
        X0 = np.fft.rfft(np.concatenate([self.old, x]))
        self.old = x
        self.X[1 : self.parts] = self.X[: self.parts - 1]
        self.X[0] = X0
        if self.nl:
            # A second branch for loudspeaker distortion: the reference through a soft
            # odd nonlinearity, which a single linear filter can't represent.
            s = x**3
            Xn = np.fft.rfft(np.concatenate([self.old_nl, s]))
            self.old_nl = s
            self.X[self.parts + 1 :] = self.X[self.parts : -1]
            self.X[self.parts] = Xn
        return np.sum(self.H * self.X, axis=0)

    def update(self, E, adapt=True):
        if not adapt:
            self.P = self.P + (1 - self.a2) * np.abs(self.H) ** 2
            return
        X2 = np.sum(np.abs(self.X) ** 2, axis=0)
        Pe = 0.5 * self.P * X2 + np.abs(E) ** 2 / self.P.shape[0]
        mu = self.P / (Pe + 1e-10)
        self.P = self.a2 * (1 - 0.5 * mu * X2) * self.P + (1 - self.a2) * np.abs(self.H) ** 2
        self.H += E * mu * self.X.conj()
        h = np.fft.irfft(self.H, axis=1)
        h[:, self.m :] = 0
        self.H = np.fft.rfft(h, axis=1)


def kalman(mic, ref, m=1024, parts=24, a=0.9995, passes=1, lead_ms=20, lag=None, nonlinear=False, seed=None):
    """Returns (error, echo estimate), both aligned to mic. `ref` is delayed so the echo
    sits `lead_ms` after the filter's first tap, which leaves room for it to arrive a
    little earlier than the global lag said."""
    n = min(len(mic), len(ref))
    mic, ref = mic[:n].astype(np.float64), ref[:n].astype(np.float64)
    d = global_lag(mic, ref) if lag is None else lag
    shift = max(d - int(lead_ms * lab.SR / 1000), 0)
    r = np.concatenate([np.zeros(shift), ref])[:n]
    f = PFDKF(m, parts, a, nonlinear=nonlinear)
    for p in range(passes):
        f.old[:] = 0
        f.old_nl[:] = 0
        f.X[:] = 0
        e = np.zeros(n)
        yh = np.zeros(n)
        for s in range(0, n - m + 1, m):
            Y = f.filt(r[s : s + m])
            y = np.fft.irfft(Y)[m:]
            err = mic[s : s + m] - y
            e[s : s + m] = err
            yh[s : s + m] = y
            E = np.fft.rfft(np.concatenate([np.zeros(m), err]))
            f.update(E)
        tail = n - (n // m) * m
        if tail:
            e[-tail:] = mic[-tail:]
    return e, yh


def residual_suppress(e, yh, n=1024, over=2.0, floor_db=-30, decay=0.6, guard=4.0):
    """Wiener-style gain from how much of the error the echo estimate explains, frame by
    frame, keeping only the smoothing state.

    The leftover echo is modelled per bin as a leak times the echo estimate's power, with
    a decay for the tail the filter missed. The guard scales that by the error's coherence
    with the estimate: when the user talks over the far side, the error isn't coherent
    with the estimate, so the gain stays near one.
    """
    h = n // 2
    w = np.sqrt(np.hanning(n + 1)[:-1])
    bins = n // 2 + 1
    Sed = np.zeros(bins, dtype=np.complex128)
    See, Sdd, fast, tail = (np.zeros(bins) for _ in range(4))
    floor = 10 ** (floor_db / 20)
    y = np.zeros(len(e), dtype=np.float32)
    for i in range(0, len(e) - n + 1, h):
        E = np.fft.rfft(w * e[i : i + n].astype(np.float64))
        D = np.fft.rfft(w * yh[i : i + n].astype(np.float64))
        Pe, Pd = np.abs(E) ** 2, np.abs(D) ** 2
        Sed = 0.9 * Sed + 0.1 * E * D.conj()
        See = 0.9 * See + 0.1 * Pe
        Sdd = 0.9 * Sdd + 0.1 * Pd
        fast = 0.5 * fast + 0.5 * Pe
        tail = np.maximum(Pd, tail * decay)
        coh = np.abs(Sed) ** 2 / (See * Sdd + 1e-20)
        leak = np.minimum((np.abs(Sed) / (Sdd + 1e-20)) ** 2, 1.0)
        R = over * leak * tail * np.clip(coh * guard, 0, 1)
        G = np.maximum(1 - R / (fast + 1e-20), floor)
        y[i : i + n] += (w * np.fft.irfft(E * G, n)).astype(np.float32)
    return y


SPEEX_DIR = lab.REPO / "Sources/Speexdsp"
SPEEX_BIN = lab.LAB / "bin/speex_run"


def speex(mic, ref, tail_ms=500, preprocess=True, lag=0):
    if not SPEEX_BIN.exists():
        SPEEX_BIN.parent.mkdir(parents=True, exist_ok=True)
        c = [str(p) for p in SPEEX_DIR.glob("*.c")]
        subprocess.run(
            ["clang", "-O2", "-DFLOATING_POINT", "-DUSE_KISS_FFT", "-DEXPORT=",
             f"-I{SPEEX_DIR}", f"-I{SPEEX_DIR}/include",
             str(Path(__file__).parent / "speex_run.c"), *c, "-lm", "-o", str(SPEEX_BIN)],
            check=True,
        )
    n = min(len(mic), len(ref))
    r = np.concatenate([np.zeros(lag, dtype=np.float32), ref[: n - lag]]) if lag else ref[:n]
    with tempfile.TemporaryDirectory() as d:
        a, b, c = Path(d, "m"), Path(d, "r"), Path(d, "o")
        (np.clip(mic[:n], -1, 1) * 32767).astype(np.int16).tofile(a)
        (np.clip(r, -1, 1) * 32767).astype(np.int16).tofile(b)
        subprocess.run([str(SPEEX_BIN), str(a), str(b), str(c), str(int(tail_ms * 48)), "1" if preprocess else "0"],
                       check=True)
        out = np.fromfile(c, dtype=np.int16).astype(np.float64) / 32768.0
    return np.concatenate([out, np.zeros(max(0, n - len(out)))])[:n]


def _k(**kw):
    def run(mic, ref):
        return kalman(mic, ref, **kw)[0]

    return run


def _kr(res=None, **kw):
    res = res or {}

    def run(mic, ref):
        e, y = kalman(mic, ref, **kw)
        return residual_suppress(e, y, **res)

    return run


def _lag_speex(tail_ms, preprocess):
    def run(mic, ref):
        lag = global_lag(mic, ref)
        return speex(mic, ref, tail_ms, preprocess, max(lag - 960, 0))

    return run


METHODS = {
    "raw": lambda m, r: m.astype(np.float64),
    "speex-live": lambda m, r: speex(m, r, 500, True),
    "speex-nopp": lambda m, r: speex(m, r, 500, False),
    "speex-aligned": _lag_speex(300, True),
    "kalman-24": _k(parts=24),
    "kalman-24-2pass": _k(parts=24, passes=2),
    "kalman-48": _k(parts=48),
    "kalman-24-a9999": _k(parts=24, a=0.9999),
    "kalman-24-a999": _k(parts=24, a=0.999),
    "kalman-m512-48": _k(m=512, parts=48),
    "kalman-nl": _k(parts=24, nonlinear=True),
    "kalman-res": _kr(parts=24),
}


def warp(r, ppm):
    """The reference on the mic's clock, by cubic interpolation, so no upsampled copy is
    held in memory. `ppm` is how much faster the mic's clock runs."""
    r = np.asarray(r, dtype=np.float32)
    t = np.arange(len(r), dtype=np.float64) * (1 - ppm * 1e-6)
    i = np.clip(t.astype(np.int64), 1, len(r) - 3)
    f = (t - i).astype(np.float32)
    a, b, c, d = r[i - 1], r[i], r[i + 1], r[i + 2]
    return b + 0.5 * f * (c - a + f * (2 * a - 5 * b + 4 * c - d + f * (3 * (b - c) + d - a)))


def sliding_ls(mic, ref, win_s=8.0, hop_s=1.0, taps=9600, lead_ms=30, lag=None, reg=1e-4, min_ref_db=-60):
    """Fits one FIR filter per window, reference to mic, by least squares, and subtracts
    its echo estimate, crossfading between windows. Non-causal: each window sees its own
    future. Near-end speech isn't correlated with the reference at these lags, so it only
    adds a little variance to the fit, which longer windows shrink.

    Returns (error, echo estimate)."""
    from scipy.linalg import solve_toeplitz

    SR = lab.SR
    n = min(len(mic), len(ref))
    mic, ref = np.asarray(mic[:n], dtype=np.float32), np.asarray(ref[:n], dtype=np.float32)
    d = global_lag(mic, ref) if lag is None else lag
    shift = max(d - int(lead_ms * SR / 1000), 0)
    x = np.concatenate([np.zeros(shift, dtype=np.float32), ref])[:n]
    W, H = int(win_s * SR), int(hop_s * SR)
    nf = 2 ** int(np.ceil(np.log2(W + taps)))
    est = np.zeros(n + nf, dtype=np.float32)
    wsum = np.zeros(n + nf, dtype=np.float32)
    last = None
    fade = np.hanning(2 * H + 1)[:-1]
    for c in range(0, n, H):
        a, b = max(c - W // 2, 0), min(c + W // 2, n)
        # float64 here on purpose: in float32 the Toeplitz solve loses about 10 dB.
        xw, yw = x[a:b].astype(np.float64), mic[a:b].astype(np.float64)
        X = np.fft.rfft(xw, nf)
        Y = np.fft.rfft(yw, nf)
        rxx = np.fft.irfft(np.abs(X) ** 2, nf)[:taps]
        rxy = np.fft.irfft(Y * X.conj(), nf)[:taps]
        if rxx[0] / max(b - a, 1) > 10 ** (min_ref_db / 10):
            rxx = rxx.copy()
            rxx[0] *= 1 + reg
            last = solve_toeplitz(rxx, rxy)
        if last is None:
            continue
        a2, b2 = max(c - H, 0), min(c + H, n)
        seg = np.fft.irfft(np.fft.rfft(x[max(a2 - taps, 0) : b2].astype(np.float64), nf) * np.fft.rfft(last, nf), nf)
        pre = a2 - max(a2 - taps, 0)
        seg = seg[pre : pre + b2 - a2]
        wf = fade[(a2 - c + H) : (a2 - c + H) + len(seg)]
        est[a2:b2] += (wf * seg).astype(np.float32)
        wsum[a2:b2] += wf
    est = est[:n] / np.maximum(wsum[:n], 1e-3)
    return mic - est, est


def _ls(win=8.0, hop=1.0, ppm="auto", res=None, **kw):
    def run(mic, ref):
        p = drift_ppm(mic, ref) if ppm == "auto" else ppm
        r = warp(np.asarray(ref, dtype=np.float64), p) if p else ref
        e, y = sliding_ls(mic, r, win_s=win, hop_s=hop, **kw)
        if res is not None:
            return residual_suppress(e, y, **res)
        return e

    return run


METHODS.update({
    "ls4": _ls(win=4.0, ppm=0),
    "ls8": _ls(win=8.0, ppm=0),
    "ls8-auto": _ls(win=8.0),
    "ls4-warp": _ls(win=4.0, ppm=8.25),
    "ls8-warp": _ls(win=8.0, ppm=8.25),
    "ls8-res": _ls(win=8.0, res={}),
    "ls8-res-30": _ls(win=8.0, res={"floor_db": -30, "over": 1.0}),
    "ls8-res-40": _ls(win=8.0, res={"floor_db": -40, "over": 4.0}),
})


METHODS.update({
    "ls8-res-50": _ls(win=8.0, res={"floor_db": -50, "over": 8.0}),
    "ls8-res-50x16": _ls(win=8.0, res={"floor_db": -50, "over": 16.0}),
    "ls4-res-40": _ls(win=4.0, res={"floor_db": -40, "over": 4.0}),
    "ls4-res-50": _ls(win=4.0, res={"floor_db": -50, "over": 8.0}),
})


def dtln(mic, ref, units=512):
    """DTLN-aec at its fixed 16 kHz (MIT code, weights' licence not stated), driven the
    way its own run_aec.py does. The result is upsampled for the level metrics, with
    nothing above 8 kHz, so its dB figures are, if anything, flattering."""
    from ai_edge_litert.interpreter import Interpreter
    from scipy.signal import resample_poly

    n = min(len(mic), len(ref))
    audio = resample_poly(mic[:n], 1, 3)
    lpb = resample_poly(ref[:n], 1, 3)
    folder = lab.LAB / "downloads/dtln/DTLN-aec/pretrained_models"
    i1 = Interpreter(model_path=str(folder / f"dtln_aec_{units}_1.tflite"))
    i2 = Interpreter(model_path=str(folder / f"dtln_aec_{units}_2.tflite"))
    i1.allocate_tensors()
    i2.allocate_tensors()
    d1, o1, d2, o2 = i1.get_input_details(), i1.get_output_details(), i2.get_input_details(), i2.get_output_details()
    s1 = np.zeros(d1[1]["shape"], dtype=np.float32)
    s2 = np.zeros(d2[1]["shape"], dtype=np.float32)
    bl, sh = 512, 128
    pad = np.zeros(bl - sh)
    a, l = np.concatenate([pad, audio, pad]), np.concatenate([pad, lpb, pad])
    out = np.zeros(len(a), dtype=np.float32)
    ib, il, ob = np.zeros(bl), np.zeros(bl), np.zeros(bl, dtype=np.float32)
    for k in range((len(a) - (bl - sh)) // sh):
        ib[:-sh], ib[-sh:] = ib[sh:], a[k * sh : k * sh + sh]
        il[:-sh], il[-sh:] = il[sh:], l[k * sh : k * sh + sh]
        F = np.fft.rfft(ib)
        i1.set_tensor(d1[0]["index"], np.abs(F).reshape(1, 1, -1).astype(np.float32))
        i1.set_tensor(d1[2]["index"], np.abs(np.fft.rfft(il)).reshape(1, 1, -1).astype(np.float32))
        i1.set_tensor(d1[1]["index"], s1)
        i1.invoke()
        mask = i1.get_tensor(o1[0]["index"])
        s1 = i1.get_tensor(o1[1]["index"])
        est = np.fft.irfft(F * mask).reshape(1, 1, -1).astype(np.float32)
        i2.set_tensor(d2[1]["index"], s2)
        i2.set_tensor(d2[0]["index"], est)
        i2.set_tensor(d2[2]["index"], il.reshape(1, 1, -1).astype(np.float32))
        i2.invoke()
        block = i2.get_tensor(o2[0]["index"])
        s2 = i2.get_tensor(o2[1]["index"])
        ob[:-sh], ob[-sh:] = ob[sh:], 0
        ob += np.squeeze(block)
        out[k * sh : k * sh + sh] = ob[:sh]
    y = out[bl - sh : bl - sh + len(audio)]
    return resample_poly(y, 3, 1)[:n]


METHODS.update({"dtln-512": lambda m, r: dtln(m, r, 512)})


METHODS.update({
    "ls8h2-res": _ls(win=8.0, hop=2.0, res={"floor_db": -50, "over": 16.0}),
})
