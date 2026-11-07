#!/usr/bin/env python
"""Sample-level lag of echo behind reference, drift, pre-echo and mic gaps, per take.

Lag comes from the sys->mic impulse response (Welch cross-spectrum, 300 Hz-6 kHz,
floored so bins with no reference energy can't dominate), not a 10 ms envelope.
  peak  : strongest tap of the response
  onset : first tap that rises 12 dB over the response's own noise, from negative lags
          upward; this is the direct sound, and answers "does echo ever lead"
  drift : each 8 s window's response is cross-correlated with the take's reference
          response, to 1/8 sample.
"""
import json
import sys

import numpy as np
from scipy.signal import get_window, hilbert

import lab

NFFT = 2**15
HOP = NFFT // 4
SPAN = int(0.5 * lab.SR)
F = np.fft.rfftfreq(NFFT, 1 / lab.SR)
MASK = np.clip((F - 200) / 100, 0, 1) * np.clip((7000 - F) / 1000, 0, 1)


def response(mic, ref):
    w = get_window("hann", NFFT, fftbins=True)
    Sxx = np.zeros(NFFT // 2 + 1)
    Syy = np.zeros(NFFT // 2 + 1)
    Sxy = np.zeros(NFFT // 2 + 1, dtype=complex)
    n = 0
    for s in range(0, len(mic) - NFFT, HOP):
        X = np.fft.rfft(w * ref[s : s + NFFT])
        Y = np.fft.rfft(w * mic[s : s + NFFT])
        Sxx += (X * X.conj()).real
        Syy += (Y * Y.conj()).real
        Sxy += Y * X.conj()
        n += 1
    if n == 0 or Sxx.sum() == 0:
        return None
    band = MASK > 0
    H = MASK * Sxy / (Sxx + 1e-3 * np.percentile(Sxx[band], 90) + 1e-20)
    h = np.fft.irfft(H, NFFT)
    coh = np.abs(Sxy) ** 2 / (Sxx * Syy + 1e-30)
    b = (F > 300) & (F < 4000)
    return np.fft.fftshift(h), float(np.mean(coh[b])), coh


def analyse(h):
    """h is fftshift-ed, with lag 0 at len/2."""
    z = len(h) // 2
    env = np.abs(hilbert(h))
    pk = int(np.argmax(env))
    # Noise of the response: far negative lags, where nothing physical can be.
    nz = env[: z // 3]
    nmean, nstd = float(nz.mean()), float(nz.std())
    above = np.where(env > max(nmean * 4, 1e-20))[0]
    onset = int(above[0]) if len(above) else pk
    e = h**2
    main = e[max(pk - 240, 0) : pk + 4800].sum()
    pre = e[z - 2400 : z].sum()  # the 50 ms before lag 0
    far = e[z // 3 : z // 3 + 2400].sum()
    return {
        "peak_ms": (pk - z) / 48.0,
        "peak_over_noise_db": float(20 * np.log10(env[pk] / (nmean + 1e-20))),
        "onset_ms": (onset - z) / 48.0,
        "energy_before_lag0_db": float(lab.db(np.array([pre / main]))[0]),
        "same_size_noise_db": float(lab.db(np.array([far / main]))[0]),
    }


def relative_shift(h, ref, pk):
    a, b = max(pk - 1024, 0), pk + 1024
    x, y = h[a:b], ref[a:b]
    X, Y = np.fft.rfft(x, 2 * len(x)), np.fft.rfft(y, 2 * len(y))
    up = np.fft.irfft(X * Y.conj(), 16 * len(x))
    score = np.max(np.abs(up)) * 8 / (np.linalg.norm(x) * np.linalg.norm(y) + 1e-20)
    i = int(np.argmax(np.abs(up)))
    if i > len(up) // 2:
        i -= len(up)
    return i / 8.0, float(score)


def zero_runs(x, min_len=48):
    d = np.diff(np.concatenate([[0], (x == 0).astype(np.int8), [0]]))
    s, e = np.where(d == 1)[0], np.where(d == -1)[0]
    return [(round(float(a) / lab.SR, 3), round(float(b - a) / 48, 1)) for a, b in zip(s, e) if b - a >= min_len]


def main(takes):
    result = {}
    for name in takes:
        mic, ref = lab.load_take(name)
        t0, t1 = lab.part1_range(name, mic, ref)
        if name == "m3-echo-off":  # skip the silent start
            t0 = max(t0, 1.0)
        a, b = int(t0 * lab.SR), int(t1 * lab.SR)
        res = {"take": name, "stretch_s": [round(t0, 2), round(t1, 2)]}
        h, coh, _ = response(mic[a:b], ref[a:b])
        res.update(analyse(h))
        res["coherence_300_4k"] = coh
        pk = int(np.argmax(np.abs(hilbert(h))))
        trace = []
        win, hop = 8 * lab.SR, 2 * lab.SR
        for s in range(0, len(mic) - win, hop):
            if np.mean(ref[s : s + win] ** 2) < 1e-7:
                continue
            r = response(mic[s : s + win], ref[s : s + win])
            if r is None:
                continue
            sh, score = relative_shift(r[0], h, pk)
            if score > 0.6:
                trace.append((round((s + win / 2) / lab.SR, 1), sh, round(score, 3)))
        if trace:
            tr = np.array(trace)
            res["windows_used"] = len(tr)
            res["shift_samples_min_max"] = [float(tr[:, 1].min()), float(tr[:, 1].max())]
            res["shift_first_last_ms"] = [float(tr[0, 1] / 48), float(tr[-1, 1] / 48)]
            if tr[-1, 0] - tr[0, 0] > 30:
                res["drift_ppm"] = float(np.polyfit(tr[:, 0], tr[:, 1], 1)[0] / lab.SR * 1e6)
            res["trace"] = trace
        nz = lab.noise_floor_power(mic, ref)
        res["noise_dbfs"] = float(lab.db(np.array([nz]))[0])
        res["mic_zero_runs_over_1ms"] = zero_runs(mic)
        result[name] = res
        print(json.dumps({k: v for k, v in res.items() if k != "trace"}, default=float), flush=True)
    (lab.LAB / "lag.json").write_text(json.dumps(result, indent=1, default=float))


if __name__ == "__main__":
    main(sys.argv[1:] or lab.TAKES)
