# AEC bench (issue 31)

Scores `EchoRemover` on clips from the [AEC-Challenge](https://github.com/microsoft/AEC-Challenge)
with the challenge's own AECMOS model, ERLE and PESQ. Public data only; nothing here touches a
user recording.

Everything downloaded goes in one bench folder outside git, `dev/tmp/aec-challenge` below.

```bash
B=dev/tmp/aec-challenge
uv venv -p 3.12 $B/.venv && uv pip install -p $B/.venv/bin/python numpy scipy soundfile librosa onnxruntime pesq
mkdir -p $B/data $B/aecmos
gh api 'repos/microsoft/AEC-Challenge/git/trees/main?recursive=1' --jq '.tree[].path' > $B/real_list.txt
curl -sSL -o $B/data/meta.csv https://raw.githubusercontent.com/microsoft/AEC-Challenge/main/datasets/synthetic/meta.csv
curl -sSL -o $B/aecmos/Run_1663915512_Stage_0.onnx https://github.com/microsoft/AEC-Challenge/raw/main/AECMOS/AECMOS_local/Run_1663915512_Stage_0.onnx
$B/.venv/bin/python -I scripts/aec-bench/pick.py $B     # 16 clips, fixed seed: 6 dev, 10 test
$B/.venv/bin/python -I scripts/aec-bench/fetch.py $B
swift build
$B/.venv/bin/python -I scripts/aec-bench/eval.py $B .build/debug/MeetingCaptureCLI all baseline
```

| Script | What it does |
|---|---|
| `pick.py` | Picks 8 real clips (far-end single talk, double talk, with movement) and 8 synthetic ones from the `test` split, seed 20261119 |
| `fetch.py` | Downloads them; the real ones are Git LFS files, fetched through `github.com/.../raw/` |
| `eval.py` | Runs the built binary (`--clean-echo`, `MEETINGCAPTURE_E2E=1`) on each clip at 48 kHz and scores it; also dumps the linear stage |
| `eval_lib.py` | Scoring shared by all: AECMOS v4 (16 kHz, scenario-aware), ERLE, PESQ-WB |
| `res_lab.py` | Tries residual suppressors in Python on the dumped linear stage |
| `search.py` | Random search over `res_lab.py`'s soft suppressor on the dev clips |
| `train_data.py` | Builds training features from the challenge's `train` split and real far-end + near-end mixes, none of the bench clips; runs the binary's linear stage, two jobs at a time |
| `nres.py` | The neural suppressor (a 0.4 M-weight GRU mask, 0-8 kHz): `nres.py train <bench>` writes `<bench>/nres.pt`; features stay memory-mapped, about 1.3 GB peak |
| `export_nres.py` | Writes `nres.pt` into `Sources/MeetingCaptureCore/EchoSuppressorWeights.swift` (half precision, base64), which `EchoSuppressor.swift` reads |

To retrain and ship new weights: `train_data.py`, `nres.py train`, `res_lab.py <bench> 'blend:geo:0.5+cn' dev`
to check it, `export_nres.py`, `swift build`, then `eval.py ... test` for the Swift numbers.
Needs `torch` in the venv. The weights come from AEC-Challenge audio, whose clips carry their
own licences (see the challenge's README); check that before publishing new weights.

Each synthetic clip is scored twice: as far-end single talk (the echo alone as the mic) and as
double talk (the challenge's mic, with the clean near-end voice for PESQ).

Unsure: AECMOS was trained on challenge-style 10 s clips, and the algorithm was tuned for whole
meetings; check the M3.2 lab takes too before trusting a change.
