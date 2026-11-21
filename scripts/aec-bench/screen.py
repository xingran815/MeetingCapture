#!/usr/bin/env python3
"""Quick screen of trained networks on public clips (issue 31), on the GPU where there is one.

  screen.py <screen dir> <net.pt> [<net.pt> ...]

The inputs come from screen_data.py. This checks the network alone: its mask applied to the
linear stage's error E, without the classical gain, comfort noise or the Swift code. So it is a
filter, not the score: a network that removes voice here is dropped; one that passes still goes
to the full scoring on the Mac (fb_eval.py, rfb_eval.py, eval.py and the user's call).

Per network, in dB (power of E over power of mask times E, over the marked frames):
  voice loss  fb-dt: synthetic double talk where the near end talks alone
              rfb-voice: real voice-only recordings (the far end quiet: the user's call case)
  echo off    fb-st and rfb-st: echo alone, where the far end is loud
each over 0-8 kHz and 8-24 kHz. Low voice loss and high echo off are good.
A network with fewer than 513 bins repeats its top 20 bins' mean above, as EchoSuppressor does.
"""
import json, sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from nres import NRES, device  # noqa: E402

LOW = 171  # bins below 8 kHz in a 1024-point frame at 48 kHz


def load(pt, dev):
    state = torch.load(pt, map_location="cpu")
    model = NRES(hidden=state["gru.weight_hh_l0"].shape[1], bins=state["out.bias"].shape[0])
    model.load_state_dict(state)
    return model.to(dev).eval()


def mask(model, le, ld):
    bins = model.out.out_features
    with torch.no_grad():
        m, _ = model(le[None, :, :bins], ld[None, :, :bins])
    m = m[0]
    if bins < le.shape[1]:
        m = torch.cat([m, m[:, -20:].mean(1, keepdim=True).expand(-1, le.shape[1] - bins)], 1)
    return m


def db(p_in, p_out):
    return float(10 * torch.log10(p_in / (p_out + 1e-20)))


def main():
    dev = device()
    clips = []
    for f in sorted(Path(sys.argv[1]).glob("*.npz")):
        z = np.load(f)
        group = f.stem.split("-")[0] + "-" + f.stem.split("-")[-1]
        key = "voice" if "voice" in z.files else "echo"
        clips.append((group, key, torch.from_numpy(z["le"].astype(np.float32)).to(dev),
                      torch.from_numpy(z["ld"].astype(np.float32)).to(dev),
                      torch.from_numpy(z[key]).to(dev)))
    print(f"{len(clips)} clips on {dev}", flush=True)
    rows = []
    for pt in sys.argv[2:]:
        model = load(pt, dev)
        sums = {}
        for group, key, le, ld, frames in clips:
            if frames.sum() < 10:
                continue
            m = mask(model, le, ld)[frames]
            p = torch.exp(le[frames])
            for band, sl in (("lo", slice(0, LOW)), ("hi", slice(LOW, None))):
                a, b = sums.setdefault((group, band), [0.0, 0.0])
                sums[(group, band)] = [a + float(p[:, sl].sum()), b + float((p[:, sl] * m[:, sl] ** 2).sum())]
        row = {"net": Path(pt).stem}
        for (group, band), (a, b) in sums.items():
            row[f"{group} {band}"] = round(db(torch.tensor(a), torch.tensor(b)), 1)
        rows.append(row)
    cols = ["fb-dt lo", "fb-dt hi", "rfb-voice lo", "rfb-voice hi", "fb-st lo", "fb-st hi", "rfb-st lo", "rfb-st hi"]
    print("voice loss (low is good): fb-dt, rfb-voice | echo off (high is good): fb-st, rfb-st")
    print(f"{'network':22s}" + "".join(f"{c:>14s}" for c in cols))
    for r in rows:
        print(f"{r['net']:22s}" + "".join(f"{r.get(c, float('nan')):14.1f}" for c in cols))
    json.dump(rows, open(Path(sys.argv[1]) / "screen_results.json", "w"), indent=1)


if __name__ == "__main__":
    main()
