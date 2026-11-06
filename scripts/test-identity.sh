#!/usr/bin/env bash
# Proves identity.sh goes red. A bad commit must never reach the public repo just
# to see this, so every case runs in a throwaway repo. Values are invented.
set -uo pipefail

while IFS= read -r var; do unset "$var"; done < <(git rev-parse --local-env-vars)

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

REPO="$WORK/repo"
git init -q -b main "$REPO"
cd "$REPO" || exit 2
if [ "$(git rev-parse --absolute-git-dir)" != "$(pwd -P)/.git" ]; then
    echo "test-identity: refusing to run, git isn't using the temporary repo." >&2
    exit 2
fi
GOOD_EMAIL="1+tester@users.noreply.github.com"
git config user.name tester
git config user.email "$GOOD_EMAIL"
git config core.hooksPath /dev/null
git init -q --bare "$WORK/remote.git"
git remote add origin "$WORK/remote.git"
mkdir scripts
cp "$SRC/scripts/sweep.sh" "$SRC/scripts/sweep-allow.txt" "$SRC/scripts/identity.sh" scripts/
: > scripts/protected-commits.sha256
git add -A && git commit -qm "chore: base"
BASE="$(git rev-parse HEAD)"
git push -q origin main

# Expects a refusal naming the reason. $1 label, $2 text to find.
refuses() {
    local out
    if out="$(scripts/identity.sh "$BASE..HEAD" 2>&1)"; then
        fail=$((fail+1)); printf '  FAIL  %s: passed\n' "$1"
    elif printf '%s' "$out" | grep -qF "$2"; then
        pass=$((pass+1)); printf '  ok    %s\n' "$1"
    else
        fail=$((fail+1)); printf '  FAIL  %s: refused, but not for the reason\n%s\n' "$1" "$out"
    fi
    git reset -q --hard "$BASE"
}

BAD_EMAIL="jo""@realmail.net"
commit_file() { printf '%s\n' "$RANDOM" > f.md; git add f.md; }

commit_file; git -c user.email="$BAD_EMAIL" commit -qm "feat: x" --author="tester <$GOOD_EMAIL>"
refuses "private committer email" "[identity-author]"

commit_file; git commit -qm "feat: x" --author="tester <$BAD_EMAIL>"
refuses "private author email" "[identity-author]"

commit_file; git commit -qm "$(printf 'feat: x\n\nCo-Authored''-By: Claude <noreply@anthropic.com>')"
refuses "AI attribution" "[ai-attribution]"

commit_file; git commit -qm "feat: from the protected branch"
printf '%s' "$(git rev-parse HEAD)" | shasum -a 256 | cut -d' ' -f1 > scripts/protected-commits.sha256
refuses "commit from the protected branch" "comes from feature/coding-interview"
: > scripts/protected-commits.sha256

git branch feature/coding-interview
git push -q origin refs/heads/feature/coding-interview
commit_file; git commit -qm "feat: fine"
refuses "protected branch on the remote" "is on the remote"
git push -q origin --delete refs/heads/feature/coding-interview
git branch -qD feature/coding-interview

commit_file; git commit -qm "feat: fine"
if out="$(scripts/identity.sh "$BASE..HEAD" 2>&1)"; then
    pass=$((pass+1)); printf '  ok    clean commit passes\n'
else
    fail=$((fail+1)); printf '  FAIL  clean commit refused\n%s\n' "$out"
fi

printf '\nidentity tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
