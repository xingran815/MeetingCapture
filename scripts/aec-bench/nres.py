#!/usr/bin/env python3
"""A small neural residual-echo suppressor (issue 31): a per-bin mask (0-8 kHz, or full band), from the
linear stage's error E and echo estimate D. About 0.4 M parameters; features stay on disk
(memory-mapped float16), so training stays far under the Mac's free RAM.

  nres.py train <bench> [steps]     trains on <bench>/train/feat (0-8 kHz), writes <bench>/nres.pt
  nres.py train-fb <bench> [steps]  trains on <bench>/fb/feat (all 513 bins, fb_data.py), writes
                                    <bench>/nres_fb.pt
  nres.py train-mix <bench> [steps] [--seed N --hidden H --keep K --out F --real-far-only]
                                    one full-band network on every set, writes <bench>/nres_mix.pt
"""
import sys
from pathlib import Path

import numpy as np
import torch
import torch.nn as nn

BINS = 171


class NRES(nn.Module):
    def __init__(self, hidden=160, bins=BINS):
        super().__init__()
        self.inp = nn.Sequential(nn.Linear(3 * bins, hidden), nn.LayerNorm(hidden), nn.PReLU())
        self.gru = nn.GRU(hidden, hidden, num_layers=2, batch_first=True)
        self.out = nn.Linear(hidden, bins)

    @staticmethod
    def features(le, ld):
        # Log powers, roughly centred; their difference is the classical echo-to-error ratio.
        le, ld = (le + 12) / 6, (ld + 12) / 6
        return torch.cat([le, ld, le - ld], dim=-1)

    def forward(self, le, ld, h=None):
        x = self.inp(self.features(le, ld))
        y, h = self.gru(x, h)
        return torch.sigmoid(self.out(y)), h


def device():
    """CUDA on a GPU machine, MPS on a Mac, else the CPU."""
    if torch.cuda.is_available():
        return torch.device("cuda")
    return torch.device("mps" if torch.backends.mps.is_available() else "cpu")


def load_bank(feat_dir, keys=("le", "ld", "s", "e"), bins=BINS):
    """All clips concatenated into one memory-mapped float16 array: [frames, len(keys), bins]."""
    feat_dir = Path(feat_dir)
    bank = feat_dir.parent / "bank.f16"
    index = feat_dir.parent / "bank_index.npy"
    files = sorted(feat_dir.glob("*.npz"))
    if not bank.exists() or np.load(index).shape[0] != len(files):
        lens = []
        with open(bank, "wb") as f:
            for p in files:
                z = np.load(p)
                a = np.stack([z[k] for k in keys], axis=1).astype(np.float16)
                f.write(a.tobytes())
                lens.append(len(a))
        np.save(index, np.array(lens))
    lens = np.load(index)
    data = np.memmap(bank, dtype=np.float16, mode="r", shape=(int(lens.sum()), len(keys), bins))
    starts = np.concatenate([[0], np.cumsum(lens)[:-1]])
    return data, starts, lens, [p.stem for p in files]


def loss_fn(mask, s, e, c=0.3, keep_weight=1.0, w=None):
    y = (mask * e).clamp_min(1e-8) ** c
    t = s.clamp_min(1e-8) ** c
    # Taking away the near end costs extra: that is the voice score the classical one loses.
    err = (y - t) ** 2 + keep_weight * torch.relu(t - y) ** 2
    if w is None:
        return err.mean()
    return (err * w).sum() / w.expand_as(err).sum()


def train(bench, steps=4000, seq=200, batch=32, seed=0, full=False):
    torch.manual_seed(seed)
    rng = np.random.default_rng(seed)
    dev = device()
    bins = 513 if full else BINS
    keys = ("le", "ld", "s") if full else ("le", "ld", "s", "e")
    data, starts, lens, names = load_bank(Path(bench) / ("fb/feat" if full else "train/feat"), keys, bins)
    weights = Path(bench) / ("nres_fb.pt" if full else "nres.pt")
    ok = np.where(lens > seq)[0]
    val = ok[rng.permutation(len(ok))[: max(len(ok) // 20, 4)]]
    tr = np.setdiff1d(ok, val)
    print(f"{len(names)} clips, {lens.sum()} frames, train {len(tr)} val {len(val)}, on {dev}", flush=True)
    model = NRES(bins=bins).to(dev)
    print(sum(p.numel() for p in model.parameters()), "parameters", flush=True)
    opt = torch.optim.AdamW(model.parameters(), lr=2e-3, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=2e-3, total_steps=steps)

    def batch_of(ids):
        x = np.empty((len(ids), seq, len(keys), bins), np.float32)
        for j, i in enumerate(ids):
            o = starts[i] + rng.integers(0, lens[i] - seq)
            x[j] = data[o:o + seq]
        x = torch.from_numpy(x).to(dev)
        e = x[:, :, 3] if len(keys) == 4 else torch.sqrt(torch.exp(x[:, :, 0]))  # |E| from log|E|^2
        return x[:, :, 0], x[:, :, 1], x[:, :, 2], e

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
                torch.save(model.state_dict(), weights)
    print("best val", best, flush=True)


SILENT = float(np.log(1e-10))  # log|X|^2 of an empty bin, as the features store it


def far_active(data, starts, lens, below_db=30.0):
    """Per frame of a bank: is the linear stage's echo estimate within below_db of the clip's loud
    frames (90th percentile)? A real recording's room sound in a far-silent frame isn't echo."""
    act = np.zeros(int(lens.sum()), bool)
    for o, n in zip(starts, lens):
        d = np.exp(data[o:o + n, 1].astype(np.float32)).sum(1)
        act[o:o + n] = d >= np.percentile(d, 90) * 10 ** (-below_db / 10)
    return act


def train_mix(bench, steps=4000, seq=200, batch=32, seed=0, hidden=160, keep_weight=1.0, out="nres_mix.pt",
              lr=2e-3, real_far_only=False):
    """One full-band network on every set there is: the 48 kHz synthetic clips (fb/feat, 513
    bins), the 16 kHz challenge clips (train/feat, 171 bins, real recordings among them) and,
    once real_data.py has run, the real 48 kHz calls (rfb/feat, 513 bins, only tracks with
    sound above 8 kHz). A 16 kHz clip has nothing above 8 kHz, so its upper bins are fed as
    silence and left out of the loss. Each batch takes an equal share from each set. Writes
    <bench>/<out> (nres_mix.pt by default).

    On a CUDA GPU every set is loaded into GPU memory once and each batch is cut there with one
    gather, so the GPU never waits on the CPU; elsewhere the sets stay memory-mapped on disk (low
    memory). Always float32: lower precision was ruled out (issue 31)."""
    torch.manual_seed(seed)
    rng = np.random.default_rng(seed)
    dev = device()
    banks = [load_bank(Path(bench) / "fb/feat", ("le", "ld", "s"), 513),
             load_bank(Path(bench) / "train/feat", ("le", "ld", "s", "e"), BINS)]
    if any((Path(bench) / "rfb/feat").glob("*.npz")):
        banks.append(load_bank(Path(bench) / "rfb/feat", ("le", "ld", "s"), 513))
    splits = []
    for data, starts, lens, names in banks:
        ok = np.where(lens > seq)[0]
        val = ok[rng.permutation(len(ok))[: max(len(ok) // 20, 4)]]
        splits.append((np.setdiff1d(ok, val), val))
        print(f"{len(names)} clips, {lens.sum()} frames, train {len(splits[-1][0])} val {len(val)}", flush=True)
    gpu = dev.type == "cuda"
    if gpu:  # le, ld, s of every set, resident on the GPU
        resident = [torch.from_numpy(np.ascontiguousarray(d[:, :3])).to(dev) for d, *_ in banks]
        span = torch.arange(seq, device=dev)
        print(f"features on the GPU: {sum(r.numel() * 2 for r in resident) / 2**30:.1f} GB", flush=True)
    model = NRES(hidden=hidden, bins=513).to(dev)
    print(sum(p.numel() for p in model.parameters()), "parameters, on", dev, flush=True)
    opt = torch.optim.AdamW(model.parameters(), lr=lr, weight_decay=1e-4)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=lr, total_steps=steps)
    # Real calls: their echo-only recordings carry room sound and stray near-end sound where the
    # far end is silent, and the target there is silence. Trained on, that teaches the network to
    # remove any sound with no far end, the user's voice included (real-seed0 took 25 dB off a
    # voice). real_far_only leaves the far-silent frames of the real set out of the loss.
    active = {}
    if real_far_only and len(banks) == 3:
        active[2] = far_active(*banks[2][:3])
        print(f"real set: {active[2].mean():.0%} of frames have the far end active", flush=True)
    active_gpu = {b: torch.as_tensor(a, device=dev).float() for b, a in active.items()} if gpu else {}

    def batch_of(b, ids):
        data, starts, lens, _ = banks[b]
        n = data.shape[2]
        if gpu:
            first = starts[ids] + (rng.random(len(ids)) * (lens[ids] - seq)).astype(np.int64)
            rows = torch.as_tensor(first, device=dev)[:, None] + span  # [batch, seq]
            x = torch.full((len(ids), seq, 3, 513), SILENT, device=dev)
            x[:, :, 2] = 0
            x[..., :n] = resident[b][rows].float()
            w = torch.zeros((len(ids), 1, 513), device=dev)
            w[..., :n] = 1
            if b in active:
                w = w * active_gpu[b][rows][..., None]
            return x[:, :, 0], x[:, :, 1], x[:, :, 2], torch.sqrt(torch.exp(x[:, :, 0])), w.expand(-1, seq, -1)
        x = np.full((len(ids), seq, 3, 513), SILENT, np.float32)
        x[:, :, 2] = 0
        firsts = []
        for j, i in enumerate(ids):
            o = starts[i] + rng.integers(0, lens[i] - seq)
            firsts.append(o)
            x[j, :, :, :n] = data[o:o + seq, :3]
        w = np.zeros((len(ids), 1, 513), np.float32)
        w[:, :, :n] = 1
        if b in active:
            w = w * np.stack([active[b][o:o + seq] for o in firsts])[..., None]
        x, w = torch.from_numpy(x).to(dev), torch.from_numpy(w).to(dev)
        return x[:, :, 0], x[:, :, 1], x[:, :, 2], torch.sqrt(torch.exp(x[:, :, 0])), w.expand(-1, seq, -1)

    def joined(parts):
        return [torch.cat(t) for t in zip(*parts)]

    weights, best = Path(bench) / out, 1e9
    for step in range(1, steps + 1):
        model.train()
        le, ld, s, e, w = joined([batch_of(b, rng.choice(splits[b][0], batch // len(banks)))
                                  for b in range(len(banks))])
        m = model(le, ld)[0]
        loss = loss_fn(m, s, e, keep_weight=keep_weight, w=w)
        opt.zero_grad(); loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 1.0)
        opt.step(); sched.step()
        if step % 250 == 0 or step == steps:
            model.eval()
            vb = 64 if gpu else 8
            with torch.no_grad():
                vl = []
                for b in range(len(banks)):
                    val = splits[b][1]
                    vl.append(np.mean([_val(model, batch_of(b, val[k:k + vb])) for k in range(0, len(val), vb)]))
            print(f"step {step} train {loss.item():.4f} val", " ".join(f"{v:.4f}" for v in vl), flush=True)
            if sum(vl) < best:
                best = sum(vl)
                torch.save(model.state_dict(), weights)
    print("best val", best, flush=True)
    try:
        import resource  # peak memory, for the RAM budget
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        print(f"peak memory {rss / (2**30 if sys.platform == 'darwin' else 2**20):.1f} GB", flush=True)
    except ImportError:
        pass


def _val(model, b):
    le, ld, s, e, w = b
    return loss_fn(model(le, ld)[0], s, e, w=w).item()


def mask_for(le, ld, weights):
    """le, ld: [frames, BINS] float arrays -> mask [frames, BINS], run on the CPU, whole clip."""
    state = torch.load(weights, map_location="cpu")
    model = NRES(bins=state["out.bias"].shape[0])
    model.load_state_dict(state)
    model.eval()
    with torch.no_grad():
        m, _ = model(torch.from_numpy(le[None].astype(np.float32)), torch.from_numpy(ld[None].astype(np.float32)))
    return m[0].numpy()


if __name__ == "__main__" and sys.argv[1] == "train-mix":
    import argparse
    a = argparse.ArgumentParser(prog="nres.py train-mix")
    a.add_argument("bench"); a.add_argument("steps", nargs="?", type=int, default=4000)
    a.add_argument("--seed", type=int, default=0); a.add_argument("--hidden", type=int, default=160)
    a.add_argument("--keep", type=float, default=1.0, help="extra cost of taking away the near end")
    a.add_argument("--batch", type=int, default=32, help="clips per step, shared equally by the sets")
    a.add_argument("--out", default="nres_mix.pt")
    a.add_argument("--lr", type=float, default=2e-3)
    a.add_argument("--real-far-only", action="store_true", help="real calls: train only where the far end is active")
    o = a.parse_args(sys.argv[2:])
    train_mix(o.bench, o.steps, batch=o.batch, seed=o.seed, hidden=o.hidden, keep_weight=o.keep, out=o.out,
              lr=o.lr, real_far_only=o.real_far_only)
elif __name__ == "__main__" and sys.argv[1] in ("train", "train-fb"):
    train(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 4000, full=sys.argv[1] == "train-fb")
