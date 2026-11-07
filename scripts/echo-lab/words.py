#!/usr/bin/env python
"""Scores a cleaned mic through the product's own transcript. Usage: words.py <method> <take>.

Puts the cleaned mic and the raw system track in one two-track WAV in the lab folder and
runs the real binary on it with `--no-aec`, because the mic is already cleaned. So this scores
a method's audio without the product's line check; for the product itself, run the binary on
the raw take and use `--txt`. Only the
scripted, invented takes are allowed (lab.TAKES).

You-words are matched first to the user's script, and only inside each line's time
window, so an echo in the other side's slot can't pass as a repeat. What's left is matched
to the other side's script: those are the echo words. What's left after that is invented.
"""
import json
import re
import subprocess
import sys
from pathlib import Path

import numpy as np

import lab

MODEL = "openai_whisper-small"
FOLDER = Path.home() / "Documents/huggingface/models/argmaxinc/whisperkit-coreml" / MODEL
BIN = lab.REPO / ".build/release/MeetingCaptureCLI"

ONES = "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen".split()
TENS = "x x twenty thirty forty fifty sixty seventy eighty ninety".split()
ORD = {"1st": "first", "2nd": "second", "3rd": "third", "26th": "twenty sixth"}
EARLY = {24, 29}  # spoken before their tone, per TAKE-NOTES.md
# main-2 lines the user got wrong, per TAKE-NOTES.md. Left out of the scores for that take.
EXCLUDED = {"main-2": {13, 14, 20, 21, 22}}


def num(n):
    if n < 20:
        return ONES[n]
    if n < 100:
        return TENS[n // 10] + ("" if n % 10 == 0 else " " + ONES[n % 10])
    return str(n)


def norm(text):
    t = text.lower().replace("’", "'")
    t = re.sub(r"\$(\d+)", r"\1 dollars", t)
    t = re.sub(r"(\d+)\s*(am|pm|a\.m\.|p\.m\.)", r"\1", t)
    t = re.sub(r"(\d+):00", r"\1 o'clock", t)
    for k, v in ORD.items():
        t = t.replace(k, v)
    t = re.sub(r"\b(\d{1,2})\b", lambda m: num(int(m.group(1))), t)
    t = re.sub(r"[^a-z' ]+", " ", t.replace("-", " "))
    return t.split()


def parse(path):
    """[(seconds, speaker, [words])], one per transcript line, with each word's time
    spread evenly from the line's start, at most 0.45 s a word."""
    lines = []
    for line in Path(path).read_text().splitlines():
        m = re.match(r"\[(\d+):(\d+):(\d+)\] (.+?): (.*)", line)
        if m:
            h, mi, s, who, text = m.groups()
            lines.append((int(h) * 3600 + int(mi) * 60 + int(s), who, norm(text)))
    return lines


def timed_words(lines, who_is):
    """[(earliest, latest, word)]. The .txt only gives each line's start, and Whisper can
    put two script lines in one segment, so a word may be anywhere up to the speaker's
    next line. Evenly spreading words misplaced whole lines, which read as lost repeats."""
    chosen = [x for x in lines if who_is(x[1])]
    out = []
    for i, (t, _, ws) in enumerate(chosen):
        nxt = chosen[i + 1][0] if i + 1 < len(chosen) else t + len(ws) * 0.45
        out += [(t, max(nxt, t + 1), w) for w in ws]
    return out


def align(hyp, truth, slack_before, slack_after):
    """Longest common word sequence, a word counting only inside its line's window.
    hyp is [(earliest, latest, w)], truth is [(start, end, w, id)]. Returns matched (hyp_i, truth_i)."""
    n, m = len(hyp), len(truth)
    dp = np.zeros((n + 1, m + 1), dtype=np.int32)
    ok = np.zeros((n, m), dtype=bool)
    for i, (t0, t1, w) in enumerate(hyp):
        for j, (a, b, tw, _) in enumerate(truth):
            ok[i, j] = w == tw and t1 >= a - slack_before and t0 <= b + slack_after
    for i in range(n - 1, -1, -1):
        for j in range(m - 1, -1, -1):
            dp[i, j] = max(dp[i + 1, j], dp[i, j + 1], (dp[i + 1, j + 1] + 1) if ok[i, j] else 0)
    i = j = 0
    pairs = []
    while i < n and j < m:
        if ok[i, j] and dp[i, j] == dp[i + 1, j + 1] + 1:
            pairs.append((i, j))
            i += 1
            j += 1
        elif dp[i + 1, j] >= dp[i, j + 1]:
            i += 1
        else:
            j += 1
    return pairs


def score(lines, offset, take):
    excluded = EXCLUDED.get(take, set())
    you_truth, them_truth = [], []
    for e in lab.events(offset):
        words = norm(e["text"])
        if e["kind"] == "you":
            if e.get("line") in excluded:
                continue
            a = e["start"] - (9 if e.get("line") in EARLY else 0)
            you_truth += [(a, e["end"], w, e["line"]) for w in words]
        else:
            # S5 is left out of `them`: the user repeats those words, so a You word matches
            # the repeat first and S5's echo can never register (from the M3.2 review).
            if e["section"].startswith("S5"):
                continue
            # The section is in the id so a section's echo can be counted apart.
            them_truth += [(e["start"], e["end"], w, e["section"].split()[0]) for w in words]
    you = timed_words(lines, lambda s: s == "You")
    others = timed_words(lines, lambda s: s != "You")
    p = align(you, you_truth, 4, 5)
    kept = np.zeros(len(you_truth), dtype=bool)
    used = set()
    for i, j in p:
        kept[j] = True
        used.add(i)
    left = [x for i, x in enumerate(you) if i not in used]
    q = align(left, them_truth, 4, 6)
    used2 = {i for i, _ in q}
    echo_by_section = {}
    for _, j in q:
        echo_by_section[them_truth[j][3]] = echo_by_section.get(them_truth[j][3], 0) + 1
    them_by_section = {}
    for t in them_truth:
        them_by_section[t[3]] = them_by_section.get(t[3], 0) + 1
    per_line = {}
    for k, t in zip(kept, you_truth):
        a = per_line.setdefault(t[3], [0, 0])
        a[0] += int(k)
        a[1] += 1
    sys_p = align(others, them_truth, 4, 6)
    res = {
        "you_kept_pct": round(100 * kept.mean(), 1),
        "them_under_you_pct": round(100 * len(q) / len(them_truth), 1),
        "them_under_you_words": len(q),
        "them_under_you_by_section": {k: f"{v}/{them_by_section[k]}" for k, v in sorted(echo_by_section.items())},
        "invented_under_you": len(left) - len(used2),
        "you_words_total": len(you),
        "them_kept_under_others_pct": round(100 * len(sys_p) / len(them_truth), 1),
        "speakers": sorted({x[1] for x in lines}),
        "them_under_you_list": [left[i][2] for i, _ in q][:0],
        "you_alone_kept_pct": _pct({k: per_line[k] for k in range(1, 13) if k in per_line}),
        "overlap_13_19": {k: per_line[k] for k in range(13, 20) if k in per_line},
        "repeats_20_29": {k: per_line[k] for k in range(20, 30) if k in per_line},
    }
    res["overlap_kept_pct"] = _pct(res["overlap_13_19"])
    res["repeat_kept_pct"] = _pct(res["repeats_20_29"])
    return res


def _pct(d):
    a = sum(v[0] for v in d.values())
    b = sum(v[1] for v in d.values())
    return round(100 * a / max(b, 1), 1)


def run(method, take):
    mic, ref = lab.load_take(take)
    work = lab.LAB / "words" / method
    work.mkdir(parents=True, exist_ok=True)
    out, rate = lab.read_wav(lab.out_path(method, take))
    n = min(len(out), len(ref))
    wav = work / f"{take}.wav"
    stereo = np.stack([out[:n, 0], ref[:n]], axis=1)
    import wave

    with wave.open(str(wav), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(lab.SR)
        w.writeframes((np.clip(stereo, -1, 1) * 32767).astype(np.int16).tobytes())
    txt = wav.with_suffix(".txt")
    log = work / f"{take}.log"
    with log.open("w") as f:
        subprocess.run(
            [str(BIN), "--transcribe-only", str(wav), "--model", MODEL, "--model-folder", str(FOLDER), "--language", "en", "--no-aec"],
            check=True, stdout=f, stderr=subprocess.STDOUT, timeout=900,
        )
    wav.unlink(missing_ok=True)
    off = lab.playback_offset(ref, take)
    res = {"method": method, "take": take, **score(parse(txt), off, take)}
    print(json.dumps(res), flush=True)
    with (lab.LAB / "words.jsonl").open("a") as f:
        f.write(json.dumps(res) + "\n")


if __name__ == "__main__":
    if sys.argv[1] == "--txt":
        # An existing transcript: words.py --txt <path> <take> <name>
        _, ref = lab.load_take(sys.argv[3])
        off = lab.playback_offset(ref, sys.argv[3])
        print(json.dumps({"method": sys.argv[4], "take": sys.argv[3], **score(parse(sys.argv[2]), off, sys.argv[3])}))
    else:
        run(sys.argv[1], sys.argv[2])
