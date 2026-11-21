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
| `fb_data.py` | Full band: reads 48 kHz clips one file at a time out of the challenge's 26 GB `fullband_synthetic.zip` with HTTP range requests (nothing near its size is stored), keeps 6 dev and 10 test clips, and builds training features for all 513 bins; seed 20261120 |
| `fb_eval.py` | Scores the binary on those 16 clips at 48 kHz: the challenge's 48 kHz AECMOS, ERLE whole band and 8-24 kHz, high-band voice loss, PESQ-WB |
| `real_data.py` | Real full-band calls: reads the challenge's `fullband.zip` (real PC calls) by HTTP range requests; a track is used only if 8-24 kHz really carries sound (loud frames 10 dB over quiet ones), each keep or skip logged in `<bench>/rfb/filter.jsonl`; keeps 10 whole sessions as a real test, seed 20261121 |
| `rfb_eval.py` | Scores the binary on those 10 real sessions: AECMOS echo and degradation (48 kHz, no clean reference needed), ERLE whole band and 8-24 kHz |
| `screen_data.py`, `screen.py` | A quick filter of trained networks on a GPU: the mask alone on public clips, voice loss and echo removed per band. Written on the training machine and not yet run on the Mac; the real scores are still `fb_eval.py`, `rfb_eval.py`, `eval.py` |
| `sweep.sh` | Trains a list of runs one after another on a training-only machine, from a list file of one run per line; restartable |
| `nres.py` | The neural suppressor (a GRU mask): `nres.py train <bench>` (0-8 kHz, 0.4 M weights) writes `<bench>/nres.pt`; `nres.py train-fb <bench>` (all 513 bins, 0.64 M weights, about 3 GB peak and 7 minutes) writes `<bench>/nres_fb.pt` |
| `export_nres.py` | Writes either into `Sources/MeetingCaptureCore/EchoSuppressorWeights.swift` (half precision, base64, with its bin count), which `EchoSuppressor.swift` reads |

To retrain and ship new weights: `train_data.py`, `nres.py train`, `res_lab.py <bench> 'blend:geo:0.5+cn' dev`
to check it, `export_nres.py`, `swift build`, then `eval.py ... test` for the Swift numbers.
Shipped weights (issue 31, D-107): `nres.py train-mix <bench> 20000 --batch 192 --real-far-only --keep 8`
on every set (synthetic 48 kHz, the 16 kHz clips, the real full-band calls), float32, about 15 minutes
on one H200. `--real-far-only` leaves real-call frames with a quiet far end out of the loss; `--keep`
weighs taking the user's voice away (1 to 4 still lost voice on the M3.2 takes; 16 removed less echo).
Score a candidate with `fb_eval.py`, `rfb_eval.py`, `eval.py` and the M3.2 takes (`echo-lab/run.py product
<take> --sim` with `MEETINGCAPTURE_LAB_BIN` pointing at a release build, about 3x quicker than debug).
Full band: `fb_data.py <bench> <binary> 1000` (about 2 hours, mostly download), `nres.py train-fb`,
`export_nres.py <bench>/nres_fb.pt ...`, `swift build`, then `fb_eval.py ... test` and `eval.py ... test`.
Needs `torch` in the venv. The weights come from AEC-Challenge audio, whose clips carry their
own licences (see the challenge's README); check that before publishing new weights.

Each synthetic clip is scored twice: as far-end single talk (the echo alone as the mic) and as
double talk (the challenge's mic, with the clean near-end voice for PESQ).

Unsure: AECMOS was trained on challenge-style 10 s clips, and the algorithm was tuned for whole
meetings; check the M3.2 lab takes too before trusting a change.
