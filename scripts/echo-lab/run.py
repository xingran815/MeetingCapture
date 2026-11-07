#!/usr/bin/env python
"""One method on one take: writes the cleaned mic and prints every level metric as one
JSON line. Usage: run.py <method> <take> [--sim]. Words are scored separately, in words.py.
"""
import json
import sys
import time

import lab

lab.single_thread()
import numpy as np  # noqa: E402

import methods  # noqa: E402


def main(method, take, sim=False):
    fn = methods.METHODS[method]
    mic, ref = lab.load_take(take)
    t = time.perf_counter()
    out = fn(mic, ref)
    took = time.perf_counter() - t
    lab.write_wav(lab.out_path(method, take), out)
    t0, t1 = lab.part1_range(take, mic, ref)
    res = {"method": method, "take": take, "x_realtime": round(len(mic) / lab.SR / took, 1)}
    res["part1"] = lab.echo_reduction(mic, out, ref, t0, t1)
    if take in ("main-3", "main-2"):
        res["part2"] = lab.alone_diff(mic, out, lab.playback_offset(ref, take))
    if sim and take in ("main-3", "main-2"):
        s = lab.build_sim(take)
        o = fn(s["mic"], s["ref"])
        res["sim"] = lab.sim_report(s, o)
    print(json.dumps(res, default=float), flush=True)
    path = lab.LAB / "results.jsonl"
    with path.open("a") as f:
        f.write(json.dumps(res, default=float) + "\n")


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    main(args[0], args[1], "--sim" in sys.argv)
