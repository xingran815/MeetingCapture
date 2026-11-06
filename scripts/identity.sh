#!/usr/bin/env bash
# For a range of commits: noreply author and committer, no AI attribution, the
# protected branch absent from the remote, and no commit from it in the range.
#
# Protected commits are listed as hashes of their ids. Some of them are pre-rewrite
# commits that GitHub still serves with the old email until it purges them, so a
# public list of plain ids would point straight at that email.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

[ $# -ge 1 ] || { echo "usage: identity.sh RANGE" >&2; exit 2; }
PROTECTED_BRANCH="feature/coding-interview"
LIST="scripts/protected-commits.sha256"
failed=0

scripts/sweep.sh --identity "$@" || failed=1

if [ -n "$(git ls-remote --heads origin "refs/heads/$PROTECTED_BRANCH")" ]; then
    echo "identity: FAILED, $PROTECTED_BRANCH is on the remote." >&2
    failed=1
fi

[ -f "$LIST" ] || { echo "identity: FAILED, $LIST is missing." >&2; exit 1; }
revs="$(git rev-list "$@")" || { echo "identity: bad range" >&2; exit 2; }
for sha in $revs; do
    hash="$(printf '%s' "$sha" | shasum -a 256 | cut -d' ' -f1)"
    if grep -qxF "$hash" "$LIST"; then
        echo "identity: FAILED, commit ${sha:0:9} comes from $PROTECTED_BRANCH." >&2
        failed=1
    fi
done

[ "$failed" -eq 0 ] && echo "identity: ok"
exit "$failed"
