#!/usr/bin/env python3
"""A small neural residual-echo suppressor (issue 31): a per-bin mask over 0-8 kHz, from the
linear stage's error E and echo estimate D. About 0.4 M parameters; features stay on disk
(memory-mapped float16), so training stays far under the Mac's free RAM.

  nres.py train <bench> [steps]     trains on <bench>/train/feat, writes <bench>/nres.pt
"""
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

BINS = 171


class NRES(nn.Module):
    def __init__(self, hidden=160):
        super().__init__()
        self.inp = nn.Sequential(nn.Linear(3 * BINS, hidden), nn.LayerNorm(hidden), nn.PReLU())
        self.gru = nn.GRU(hidden, hidden, num_layers=2, batch_first=True)
        self.out = nn.Linear(hidden, BINS)

    @staticmethod
    def features(le, ld):
        # Log powers, roughly centred; their difference is the classical echo-to-error ratio.
        le, ld = (le + 12) / 6, (ld + 12) / 6
        return torch.cat([le, ld, le - ld], dim=-1)

    def forward(self, le, ld, h=None):
        x = self.inp(self.features(le, ld))
        y, h = self.gru(x, h)
        return torch.sigmoid(self.out(y)), h


def load_bank(feat_dir):
    """All clips concatenated into one memory-mapped float16 array: [frames, 4, BINS]."""
    feat_dir = Path(feat_dir)
    bank = feat_dir.parent / "bank.f16"
    index = feat_dir.parent / "bank_index.npy"
    files = sorted(feat_dir.glob("*.npz"))
    if not bank.exists() or np.load(index).shape[0] != len(files):
        lens = []
        with open(bank, "wb") as f:
            for p in files:
                z = np.load(p)
                a = np.stack([z["le"], z["ld"], z["s"], z["e"]], axis=1).astype(np.float16)
                f.write(a.tobytes())
                lens.append(len(a))
        np.save(index, np.array(lens))
    lens = np.load(index)
    data = np.memmap(bank, dtype=np.float16, mode="r", shape=(int(lens.sum()), 4, BINS))
    starts = np.concatenate([[0], np.cumsum(lens)[:-1]])
    return data, starts, lens, [p.stem for p in files]


def loss_fn(mask, s, e, c=0.3, keep_weight=1.0):
    y = (mask * e).clamp_min(1e-8) ** c
    t = s.clamp_min(1e-8) ** c
    # Taking away the near end costs extra: that is the voice score the classical one loses.
    return ((y - t) ** 2).mean() + keep_weight * (torch.relu(t - y) ** 2).mean()


def train(bench, steps=4000, seq=200, batch=32, seed=0):
    torch.manual_seed(seed)
    rng = np.random.default_rng(seed)
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    data, starts, lens, names = load_bank(Path(bench) / "train/feat")
    ok = np.where(lens > seq)[0]
    val = ok[rng.permutation(len(ok))[: max(len(ok) // 20, 4)]]
    tr = np.setdiff1d(ok, val)
    print(f"{len(names)} clips, {lens.sum()} frames, train {len(tr)} val {len(val)}, on {dev}", flush=True)
    model = NRES().to(dev)
    print(sum(p.numel() for p in model.parameters()), "parameters", flush=True)
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=2e-3, total_steps=steps)

    def batch_of(ids):
        x = np.empty((len(ids), seq, 4, BINS), np.float32)
        for j, i in enumerate(ids):
            o = starts[i] + rng.integers(0, lens[i] - seq)
            x[j] = data[o:o + seq]
        x = torch.from_numpy(x).to(dev)
        return x[:, :, 0], x[:, :, 1], x[:, :, 2], x[:, :, 3]

    best = 1e9
    for step in range(1, steps + 1):
        model.train()
        le, ld, s, e = batch_of(rng.choice(tr, batch))
        mask, _ = model(le, ld)
        loss = loss_fn(mask, s, e)
        opt.zero_grad(); loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step(); sched.step()
        if step % 250 == 0 or step == steps:
            model.eval()
            with torch.no_grad():
                losses = []
                for k in range(0, len(val), 8):
                    le_, ld_, s_, e_ = batch_of(val[k:k + 8])
                    losses.append(loss_fn(model(le_, ld_)[0], s_, e_).item())
                vl = float(np.mean(losses))
            print(f"step {step} train {loss.item():.4f} val {vl:.4f}", flush=True)
            if vl < best:
                best = vl
                torch.save(model.state_dict(), Path(bench) / "nres.pt")
    print("best val", best, flush=True)


def mask_for(le, ld, weights):
    """le, ld: [frames, BINS] float arrays -> mask [frames, BINS], run on the CPU, whole clip."""
    model = NRES()
    model.load_state_dict(torch.load(weights, map_location="cpu"))
    model.eval()
    with torch.no_grad():
        m, _ = model(torch.from_numpy(le[None].astype(np.float32)), torch.from_numpy(ld[None].astype(np.float32)))
    return m[0].numpy()


if __name__ == "__main__" and sys.argv[1] == "train":
    train(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 4000)
