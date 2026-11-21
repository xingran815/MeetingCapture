#!/usr/bin/env python3
"""Scores the built binary on the full-band bench clips (fb_data.py) at 48 kHz.

  fb_eval.py <bench> <binary> [dev|test|all] [label]

Per clip, as far-end single talk (the echo alone as the mic) and as double talk (the
challenge's mic, near end kept in `nearend`):
  - AECMOS, the challenge's 48 kHz model (Run_1668423760), echo and degradation
  - ERLE, whole band and 8-24 kHz (single talk)
  - high-band voice loss: how much quieter the near end's 8-24 kHz is in the output, measured
    where the near end is loud and the far side is silent (double talk)
  - PESQ-WB at 16 kHz against the near end (double talk)
Writes <bench>/fb/results_<label>.json.
"""
import json, os, subprocess, sys, tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly, stft

SR = 48000
_sess = {}


def aecmos(bench, talk, lpb, mic, enh):
    import librosa
    import onnxruntime as ort
    if "s" not in _sess:
        _sess["s"] = ort.InferenceSession(str(Path(bench) / "aecmos/Run_1668423760_Stage_0.onnx"))
    sess = _sess["s"]

    def mel(x):
        m = librosa.feature.melspectrogram(y=x, sr=SR, n_fft=1537, hop_length=768, n_mels=160)
        return ((librosa.power_to_db(m, ref=np.max) + 40) / 40).T

    n = min(len(lpb), len(mic), len(enh), 20 * SR)
    f = [mel(s[:n].astype(np.float32)) for s in (lpb, mic, enh)]
    ne, fe = (0, 1) if talk == "st" else (0, 0)
    pad = lambda s, v: np.concatenate((s, np.ones((20, s.shape[1])) * v, np.zeros((20, s.shape[1]))))
    feats = np.stack((pad(f[0], 1 - ne), pad(f[1], 1 - fe), pad(f[2], 1))).astype(np.float32)[None]
    inputs = {sess.get_inputs()[0].name: feats}
    for i in sess.get_inputs()[1:]:
        inputs[i.name] = np.zeros([d if isinstance(d, int) else 1 for d in i.shape], np.float32)
    r = sess.run([], inputs)[0]
    return float(r[0]), float(r[1])


def band_power(x, lo, hi, frames=None):
    f, _, X = stft(x, SR, nperseg=1024)
    P = (np.abs(X[(f >= lo) & (f < hi)]) ** 2).sum(0)
    return P if frames is None else P[frames]


def erle(mic, out, lo=0, hi=SR / 2):
    return 10 * np.log10(band_power(mic, lo, hi).sum() / (band_power(out, lo, hi).sum() + 1e-20))


def clean(binary, mic, lpb):
    with tempfile.TemporaryDirectory() as d:
        n = min(len(mic), len(lpb))
        sf.write(f"{d}/in.wav", np.clip(np.stack([mic[:n], lpb[:n]], 1), -1, 1), SR, subtype="PCM_16")
        env = dict(os.environ, MEETINGCAPTURE_E2E="1")
        r = subprocess.run([binary, "--clean-echo", f"{d}/in.wav", "--clean-echo-out", f"{d}/out.wav"],
                           capture_output=True, text=True, env=env, timeout=300)
        if "have both tracks" in r.stderr:
            return mic[:n].copy()  # a silent far side: nothing to remove, the user gets the raw mic
        if r.returncode != 0:
            raise RuntimeError(f"binary failed: {r.stdout.strip()} {r.stderr.strip()}")
        if not Path(f"{d}/out.wav").exists():
            return mic[:n].copy()  # no echo found: the user gets the raw mic
        y, _ = sf.read(f"{d}/out.wav", dtype="float64")
        return np.pad(y, (0, max(n - len(y), 0)))[:n]


def pesq_wb(ref, deg):
    from pesq import pesq
    try:
        return pesq(16000, resample_poly(ref, 1, 3), resample_poly(deg, 1, 3), "wb")
    except Exception:
        return float("nan")


def main():
    bench, binary = Path(sys.argv[1]), sys.argv[2]
    split = sys.argv[3] if len(sys.argv) > 3 else "dev"
    label = sys.argv[4] if len(sys.argv) > 4 else "run"
    clips = [c for c in json.load(open(bench / "fb/clips.json")) if split == "all" or c["split"] == split]
    rows = []
    for c in clips:
        p = lambda k: sf.read(bench / f"fb/clips/{c['fid']}_{k}.wav", dtype="float64")[0]
        mic, lpb, echo, near = p("mic"), p("farend"), p("echo"), p("nearend")
        # single talk
        y = clean(binary, echo, lpb)
        e_raw, _ = aecmos(bench, "st", lpb, echo, echo)
        e, d = aecmos(bench, "st", lpb, echo, y)
        rows.append(dict(fid=c["fid"], split=c["split"], talk="st", mos_echo_raw=e_raw, mos_echo=e, mos_deg=d,
                         erle=erle(echo, y), erle_hi=erle(echo, y, 8000)))
        # double talk
        y = clean(binary, mic, lpb)
        n = min(len(y), len(near))
        er, dr = aecmos(bench, "dt", lpb, mic, mic)
        e, d = aecmos(bench, "dt", lpb, mic, y)
        pn, pf = band_power(near[:n], 0, SR / 2), band_power(lpb[:n], 0, SR / 2)
        k = min(len(pn), len(pf))
        alone = (pn[:k] > np.percentile(pn[:k], 60)) & (pf[:k] < np.percentile(pf[:k], 30))
        loss = float("nan")
        if alone.sum() >= 20:
            loss = 10 * np.log10(band_power(near[:n], 8000, SR / 2, None)[:k][alone].sum()
                                 / (band_power(y[:n], 8000, SR / 2, None)[:k][alone].sum() + 1e-20))
        rows.append(dict(fid=c["fid"], split=c["split"], talk="dt", mos_echo_raw=er, mos_deg_raw=dr, mos_echo=e,
                         mos_deg=d, hi_voice_loss=loss, pesq=pesq_wb(near[:n], y[:n])))
        print(json.dumps(rows[-2]), json.dumps(rows[-1]), flush=True)
    json.dump(rows, open(bench / f"fb/results_{label}.json", "w"), indent=1)
    m = lambda talk, key: np.nanmean([r[key] for r in rows if r["talk"] == talk])
    print(f"{label} {split} | ST echo {m('st','mos_echo'):.2f} (raw {m('st','mos_echo_raw'):.2f}) "
          f"ERLE {m('st','erle'):.1f} hi {m('st','erle_hi'):.1f} | DT echo {m('dt','mos_echo'):.2f} "
          f"deg {m('dt','mos_deg'):.2f} (raw {m('dt','mos_deg_raw'):.2f}) hi-voice-loss {m('dt','hi_voice_loss'):.1f} "
          f"PESQ {m('dt','pesq'):.2f}")


if __name__ == "__main__":
    main()
