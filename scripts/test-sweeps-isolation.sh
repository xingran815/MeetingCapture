#!/usr/bin/env bash
# Finding (M2.1): test-sweeps.sh damaged the real repo when a hook ran it from a
# linked worktree. This runs it with git's variables aimed at a throwaway repo and
# proves that repo is unchanged. Takes the script to test, for proving this goes red.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${1:-$SRC/scripts/test-sweeps.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Clear whatever this shell inherited, so the setup below can't touch a real repo.
while IFS= read -r var; do unset "$var"; done < <(git rev-parse --local-env-vars)

VICTIM="$WORK/victim"
git init -q -b main "$VICTIM"
git init -q --bare "$WORK/victim-remote.git"
git -C "$VICTIM" config user.name victim
git -C "$VICTIM" config user.email "2+victim@users.noreply.github.com"
git -C "$VICTIM" remote add origin "$WORK/victim-remote.git"
# The old script found its sources through git, so give it some to find.
cp -R "$SRC/scripts" "$SRC/.githooks" "$VICTIM/"
git -C "$VICTIM" add -A
git -C "$VICTIM" -c core.hooksPath=/dev/null commit -qm "chore: base"

state() {
    (
        cd "$VICTIM" || exit 2
        cat .git/config .git/HEAD
        git for-each-ref
        git rev-parse HEAD
        git status --porcelain
        git -C "$WORK/victim-remote.git" for-each-ref
    )
}
before="$(state)"

GIT_DIR="$VICTIM/.git" GIT_WORK_TREE="$VICTIM" GIT_INDEX_FILE="$VICTIM/.git/index" \
    GIT_PREFIX="" bash "$SCRIPT" > "$WORK/run.log" 2>&1
rc=$?

after="$(state)"
if [ "$before" != "$after" ]; then
    echo "isolation: FAILED, the seeded-leak tests changed the repo GIT_DIR pointed at:" >&2
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") | cut -c1-120 | head -20 >&2
    exit 1
fi
if [ "$rc" -ne 0 ]; then
    echo "isolation: FAILED, the seeded-leak tests didn't pass with GIT_DIR set:" >&2
    tail -5 "$WORK/run.log" >&2
    exit 1
fi
echo "isolation: ok, $(tail -1 "$WORK/run.log"), and the repo GIT_DIR pointed at is unchanged."
