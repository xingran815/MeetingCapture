#!/usr/bin/env python3
"""Random search over soft_res on the dev clips. Objective follows the issue-31 goal: echo MOS on
every group, plus double the double-talk degradation MOS. Usage: search.py <bench> <n> <seed>"""
import json, sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).parent))
import res_lab as L, eval_lib as ev
B, n, seed = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
SUFFIX = sys.argv[4] if len(sys.argv) > 4 else ""
rng = np.random.default_rng(seed)
space = dict(pct=(30, 85), os_=(0.5, 4), c_db=(-6, 8), slope=(0.2, 1.5), release=(0.5, 0.97),
             frame_floor_db=(-60, -10), floor_db=(-50, -15), decay=(0.3, 0.8))
for i in range(n):
    kw = {k: round(float(rng.uniform(*v)), 2) for k, v in space.items()}
    name = "soft:" + ",".join(f"{k}={v}" for k, v in kw.items())
    rows = ev.score_all(B, "dev", lambda nm, mic, lpb: L.run(name + SUFFIX, nm, mic))
    g = lambda kind, talk, key: np.mean([r[key] for r in rows if r["kind"] == kind and r["talk"] == talk])
    echo = sum(g(k, t, "mos_echo") for k, t in ev.GROUPS)
    deg = g("real", "dt", "mos_deg") + g("synthetic", "dt", "mos_deg")
    # Shortfall against the issue-31 goal, each in units of its own scale; 0 means every goal met.
    raw = lambda kind: np.mean([r["mos_deg_raw"] for r in rows if r["kind"] == kind and r["talk"] == "dt"])
    short = [(4.3 - g("real", "st", "mos_echo")) / 0.5, (4.3 - g("real", "dt", "mos_echo")) / 0.5,
             (4.0 - g("synthetic", "st", "mos_echo")) / 0.5, (4.3 - g("synthetic", "dt", "mos_echo")) / 0.5,
             (raw("real") - 0.1 - g("real", "dt", "mos_deg")) / 0.5,
             (raw("synthetic") - 0.1 - g("synthetic", "dt", "mos_deg")) / 0.5,
             (25 - g("synthetic", "st", "erle_db")) / 5, (2.0 - g("synthetic", "dt", "pesq")) / 0.5]
    obj = -sum(max(x, 0) for x in short)
    out = {"obj": round(obj, 3), "kw": kw, "echo": [round(g(k, t, "mos_echo"), 2) for k, t in ev.GROUPS],
           "deg_dt": [round(g("real", "dt", "mos_deg"), 2), round(g("synthetic", "dt", "mos_deg"), 2)],
           "erle_syn": round(g("synthetic", "st", "erle_db"), 1), "pesq": round(g("synthetic", "dt", "pesq"), 2)}
    print(json.dumps(out), flush=True)
