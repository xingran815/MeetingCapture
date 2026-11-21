#!/usr/bin/env bash
# Trains several full-band networks one after another (issue 31), for a machine that only
# trains: the features come from the Mac (rsync of <bench>/{fb,train,rfb}/feat), and the
# results go back to it to be exported and scored, since scoring needs the macOS binary.
#
#   sweep.sh <dir> <runs-file>
#
# <dir> holds nres.py, a .venv with torch and numpy, runs/, and the bench folders. Each line
# of <runs-file> is "<name> <bench folder> [arguments to nres.py train-mix]"; train-mix uses
# every feature set in that bench folder, so a folder without rfb/ trains without the real
# calls. Each run writes runs/<name>.pt and runs/<name>.log; a run with both a .pt and a
# "best val" line is skipped, so the sweep can be restarted. One at a time: the VM has 2 cores.
set -euo pipefail
set -f  # the run list's arguments are split on spaces, never globbed
dir=$1
list=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
cd "$dir"
py=.venv/bin/python
while read -r name bench args; do
  [[ -z $name || $name == \#* ]] && continue
  if [[ -f runs/$name.pt ]] && grep -q "best val" "runs/$name.log" 2>/dev/null; then
    echo "skip $name"
    continue
  fi
  echo "start $name $(date +%H:%M)"
  # shellcheck disable=SC2086  # args is a list of flags
  if "$py" -I nres.py train-mix "$bench" $args --out "$PWD/runs/$name.pt" >"runs/$name.log" 2>&1; then
    echo "done $name $(date +%H:%M) $(grep 'best val' "runs/$name.log")"
  else
    echo "failed $name, see runs/$name.log"
  fi
done <"$list"
echo "sweep finished"
