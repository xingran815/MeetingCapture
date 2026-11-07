"""Shared loading, timeline and metric code for the M3.2 echo lab.

Every method and every take goes through these same functions, so figures can be
compared. All audio stays local. Nothing here prints the text of a recording other
than the scripted, invented takes.
"""
import json
import os
import subprocess
import sys
import wave
from pathlib import Path

import numpy as np

RAW = Path.home() / "Documents/MeetingCapture-m3.2-raw"
ECHO_OFF = Path.home() / "Documents/MeetingCapture/m3-echo-off.m4a"
REPO = Path(__file__).resolve().parents[2]
LAB = REPO / "dev/tmp/echo-lab"
OUT = LAB / "out"
SR = 48000

# Only these takes may be opened. Anything else raises, by design.
TAKES = ["main-3", "main-2", "start1", "start2", "start3", "start4", "m3-echo-off"]


def read_wav(path):
    with wave.open(str(path), "rb") as w:
        n, ch, rate, width = w.getnframes(), w.getnchannels(), w.getframerate(), w.getsampwidth()
        assert width == 2, f"{path}: expected int16"
        x = np.frombuffer(w.readframes(n), dtype=np.int16)
    return x.reshape(-1, ch).astype(np.float32) / 32768.0, rate


def write_wav(path, x, rate=SR):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    y = np.clip(np.round(np.asarray(x, dtype=np.float64) * 32768.0), -32768, 32767).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(y.tobytes())


def load_take(name):
    """Returns (mic, system) as float32 at 48 kHz. ch1 is mic, ch2 is system."""
    if name not in TAKES:
        raise SystemExit(f"take {name!r} is not on the allowed list: {TAKES}")
    if name == "m3-echo-off":
        # AAC, so lossy: the decoded file is a lab copy, and every figure on this take
        # is limited by the codec's own error as well as the room.
        dec = LAB / "audio/m3-echo-off.wav"
        if not dec.exists():
            dec.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(
                ["afconvert", "-f", "WAVE", "-d", "LEI16@48000", "-c", "2", str(ECHO_OFF), str(dec)], check=True
            )
        path = dec
    else:
        path = RAW / f"{name}.wav"
    x, rate = read_wav(path)
    assert rate == SR and x.shape[1] == 2
    return x[:, 0].copy(), x[:, 1].copy()


def db(x, floor=1e-20):
    return 10 * np.log10(np.maximum(x, floor))


def frame_power(x, frame=480):
    n = len(x) // frame
    return np.mean(x[: n * frame].reshape(n, frame).astype(np.float64) ** 2, axis=1)


# --- timeline -------------------------------------------------------------------


def script():
    return json.loads((RAW / "main-friend.json").read_text())


def playback_offset(system, name):
    """Seconds to add to main-friend.json times to get file time, found by matching
    the start of what was played against the system track, so no slot is assumed."""
    from scipy.signal import fftconvolve

    cache = LAB / f"offset-{name}.json"
    if cache.exists():
        return json.loads(cache.read_text())["offset"]
    src, rate = read_wav(RAW / "main-friend.wav")
    src = src.mean(axis=1)
    assert rate == SR
    # 5.0 s to 60 s of the played file: beeps and the first lines.
    a = src[5 * SR : 60 * SR]
    s = system[: min(len(system), 90 * SR)]
    c = fftconvolve(s, a[::-1], mode="valid")
    best = int(np.argmax(np.abs(c)))
    off = best / SR - 5.0
    cache.write_text(json.dumps({"offset": off}))
    return off


def events(offset, kinds=("them", "you")):
    out = []
    for e in script()["events"]:
        if e["kind"] in kinds:
            f = dict(e)
            f["start"] = e["start"] + offset
            f["end"] = e["end"] + offset
            out.append(f)
    return out


def sections(offset):
    return {
        e["section"].split()[0]: (e["start"] + offset, e["end"] + offset)
        for e in script()["events"]
        if e["kind"] == "section"
    }


def part1_range(name, mic, system):
    """Stretch where the user is silent and only the far side plays."""
    if name == "m3-echo-off":
        # From the raw echo sample's own notes: an echo sample with the user silent.
        return 0.0, len(mic) / SR
    off = playback_offset(system, name)
    s = sections(off)["S1"]
    # Whole take for start1-4: they play only the first part, and may stop early.
    return s[0], min(s[1], len(mic) / SR)


# --- metric 1: echo reduction -----------------------------------------------------


def noise_floor_power(mic, system):
    """Quietest stretch of the mic while system is silent too: the room."""
    pm = frame_power(mic)
    ps = frame_power(system)
    n = min(len(pm), len(ps))
    quiet = pm[:n][ps[:n] < 10 ** (-70 / 10)]
    quiet = quiet[quiet > 0]
    if len(quiet) < 50:  # no silent system: 5th percentile of the mic instead.
        return float(np.percentile(pm[pm > 0], 5))
    return float(np.percentile(quiet, 25))


def echo_reduction(raw, out, system, t0, t1, noise_power=None, frame=2400, convergence_s=10.0, lag_samples=7200):
    """Reduction on the loud echo frames of a user-silent stretch.

    Frames are chosen from the RAW mic only, so a method can't pick its own best
    frames. `ceiling` is what a perfect canceller that leaves room noise untouched
    could show: raw power over room noise, in the same frames.
    """
    a, b = int(t0 * SR), min(int(t1 * SR), len(raw), len(out))
    pr = frame_power(raw[a:b], frame)
    po = frame_power(out[a:b], frame)
    t = (np.arange(len(pr)) + 0.5) * frame / SR
    if noise_power is None:
        noise_power = noise_floor_power(raw, system)
    # Loud = echo at least 10 dB over room noise, then the typical/loudest split on those.
    loud = pr > noise_power * 10
    res = {"loud_frames": int(loud.sum()), "frames": int(len(pr))}
    if not loud.any():
        return res
    after = t >= convergence_s
    d = db(pr) - db(po)
    ceil = db(pr) - db(np.full_like(pr, noise_power))

    def stats(mask):
        if not mask.any():
            return None, None
        return float(np.median(d[mask])), float(np.median(ceil[mask]))

    res["median_db"], res["median_ceiling_db"] = stats(loud & after)
    thresh = np.percentile(pr[loud], 95)
    res["loudest5_db"], res["loudest5_ceiling_db"] = stats((pr >= thresh) & after)
    res["first10s_db"], _ = stats(loud & ~after)
    res["rest_db"], _ = stats(loud & after)
    # Power-summed figure too: dominated by the frames the ear hears.
    if (loud & after).any():
        res["energy_db"] = float(db(pr[loud & after].sum()) - db(po[loud & after].sum()))
    res["noise_dbfs"] = float(db(np.array([noise_power]))[0])
    return res


# --- metric 2: semi-synthetic double talk ----------------------------------------


def si_sdr(s, y):
    s = s - s.mean()
    y = y - y.mean()
    a = np.dot(y, s) / max(np.dot(s, s), 1e-20)
    e = y - a * s
    return float(db(np.array([np.dot(a * s, a * s)]))[0] - db(np.array([np.dot(e, e)]))[0])


def sdr(s, y):
    e = y - s
    return float(db(np.array([np.dot(s, s)]))[0] - db(np.array([np.dot(e, e)]))[0])


def build_sim(name, echo_gain_db=0.0):
    """Real echo-only mic from part 1 + the user's real solo speech from part 2, at
    real levels. Truth tracks are kept. Layout, in the file's time:

      [0, t_st)     single talk: echo only, part 1 unchanged, with the same reference
      [t_st, t_dt)  double talk: part-1 echo + part-2 speech added
      [t_dt, end)   user alone: remaining part-2 speech over only room noise
    """
    mic, system = load_take(name)
    off = playback_offset(system, name)
    sec = sections(off)
    s1 = (int(sec["S1"][0] * SR), int(sec["S1"][1] * SR))
    # Part 2's lines only, not the tones between them, which echo into the mic.
    you2 = [e for e in events(off, ("you",)) if e["section"].startswith("S2")]
    near = np.concatenate([mic[int(e["start"] * SR) : int(e["end"] * SR)] for e in you2])
    # Reference covers part 1 with some pre-roll, then silence.
    pre = int(5 * SR)
    start = s1[0] - pre
    echo = mic[start : s1[1]].copy()
    ref = system[start : s1[1]].copy()
    g = 10 ** (echo_gain_db / 20)
    # Room noise has to stay real: scale only the part above it when asked.
    echo_scaled = echo * g
    ref_out = ref * g
    t_st = pre + 30 * SR
    n = len(echo)
    n_total = max(n, t_st + len(near))
    tail = n_total - n
    # After part 1 the echo track holds real room noise from the take's silent ending.
    if tail > 0:
        s6 = sec["S6"]
        quiet = mic[int(s6[0] * SR) + SR // 2 : int(s6[0] * SR) + 16 * SR]
        rep = np.tile(quiet, tail // len(quiet) + 1)[:tail]
        echo_scaled = np.concatenate([echo_scaled, rep])
        ref_out = np.concatenate([ref_out, np.zeros(tail, dtype=np.float32)])
    truth = np.zeros(n_total, dtype=np.float32)
    truth[t_st : t_st + len(near)] = near
    sim_mic = echo_scaled + truth
    return {
        "mic": sim_mic,
        "ref": ref_out,
        "echo": echo_scaled,
        "near": truth,
        "single": (pre, t_st),
        "double": (t_st, n),
        "alone": (n, n_total),
        "pre": pre,
    }


def sim_report(sim, out):
    n = min(len(out), len(sim["near"]))
    out = out[:n]
    res = {}
    nr = sim["near"][:n]
    ec = sim["echo"][:n]
    mic = sim["mic"][:n]
    # Where near-end speech is really present, by its own level.
    pn = frame_power(nr, 480)
    active = np.repeat(pn > (pn[pn > 0].max() * 10 ** (-40 / 10)), 480)
    active = np.pad(active, (0, n - len(active)))[:n]

    def part(rng):
        a, b = rng
        return a, min(b, n)

    a, b = part(sim["single"])
    res["single_reduction_db"] = float(db(np.dot(mic[a:b], mic[a:b]))) - float(db(np.dot(out[a:b], out[a:b])))
    a, b = part(sim["double"])
    m = active[a:b]
    res["double_sdr_raw"] = sdr(nr[a:b][m], mic[a:b][m])
    res["double_sdr"] = sdr(nr[a:b][m], out[a:b][m])
    res["double_si_sdr_raw"] = si_sdr(nr[a:b][m], mic[a:b][m])
    res["double_si_sdr"] = si_sdr(nr[a:b][m], out[a:b][m])
    # Echo left in double talk: remove the best-scaled near-end, then compare to echo.
    y = out[a:b]
    s = nr[a:b]
    g = np.dot(y, s) / max(np.dot(s, s), 1e-20)
    res["double_reduction_db"] = float(db(np.dot(ec[a:b], ec[a:b]))) - float(db(np.dot(y - g * s, y - g * s)))
    res["double_near_gain_db"] = float(20 * np.log10(max(abs(g), 1e-6)))
    a, b = part(sim["alone"])
    if b - a > SR:
        m = active[a:b]
        res["alone_sdr"] = sdr(mic[a:b][m], out[a:b][m])
        res["alone_level_diff_db"] = float(db(np.dot(out[a:b][m], out[a:b][m]))) - float(
            db(np.dot(mic[a:b][m], mic[a:b][m]))
        )
    return res


def alone_diff(raw, out, offset):
    """Raw vs processed while the user speaks alone in part 2 of the real take."""
    rs, ro = [], []
    for e in events(offset, ("you",)):
        if e["section"].startswith("S2"):
            a, b = int(e["start"] * SR), int(e["end"] * SR)
            rs.append(raw[a:b])
            ro.append(out[a:b])
    r = np.concatenate(rs)
    o = np.concatenate(ro)
    n = min(len(r), len(o))
    r, o = r[:n], o[:n]
    return {
        "part2_level_diff_db": float(db(np.dot(o, o))) - float(db(np.dot(r, r))),
        "part2_sdr_db": sdr(r, o),
    }


def out_path(method, take):
    return OUT / method / f"{take}.wav"


def out_sim_path(method, take, gain):
    return OUT / method / f"{take}.sim{gain:+.0f}.wav"


def log(*a):
    print(*a, file=sys.stderr, flush=True)


def single_thread():
    for k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS", "MKL_NUM_THREADS"):
        os.environ[k] = "1"
