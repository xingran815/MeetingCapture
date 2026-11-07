#!/usr/bin/env bash
# Proves lint.sh goes red for each tool, in a throwaway repo, so no bad file ever
# has to be committed to see it. Also proves a clean tree passes.
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
    echo "test-lint: refusing to run, git isn't using the temporary repo." >&2
    exit 2
fi

mkdir -p scripts .githooks .github/workflows Sources/MeetingCaptureCore Sources/MeetingCaptureCLI Tests
cp "$SRC/.swift-format" .
cp "$SRC/scripts/lint.sh" "$SRC/scripts/check-workflows.sh" scripts/
printf '#!/usr/bin/env bash\nexit 0\n' > .githooks/pre-commit
printf '// swift-tools-version: 5.9\nimport PackageDescription\n\nlet package = Package(name: "Probe")\n' > Package.swift
printf 'let probe = 1\n' > Sources/MeetingCaptureCore/Probe.swift
printf 'let probe = 2\n' > Sources/MeetingCaptureCLI/Probe.swift
printf 'let probe = 3\n' > Tests/Probe.swift
cat > .github/workflows/ci.yml <<'YML'
name: CI
on: push
permissions:
  contents: read
jobs:
  a:
    runs-on: macos-26
    timeout-minutes: 5
    steps:
      - run: echo ok
YML
git config user.name tester
git config user.email "1+tester@users.noreply.github.com"
git add -A
git commit -qm "chore: base" || { echo "base commit failed"; exit 2; }

# Expects lint to fail, naming the tool. $1 label, $2 text to find, $3 file, $4 content.
refuses() {
    local keep out
    keep="$(cat "$3")"
    printf '%s\n' "$4" > "$3"
    if out="$(scripts/lint.sh 2>&1)"; then
        fail=$((fail+1)); printf '  FAIL  %s: lint passed\n' "$1"
    elif printf '%s' "$out" | grep -qF "$2"; then
        pass=$((pass+1)); printf '  ok    %s\n' "$1"
    else
        fail=$((fail+1)); printf '  FAIL  %s: refused for another reason\n%s\n' "$1" "$out"
    fi
    printf '%s\n' "$keep" > "$3"
}

if out="$(scripts/lint.sh 2>&1)"; then
    pass=$((pass+1)); printf '  ok    clean tree passes\n'
else
    fail=$((fail+1)); printf '  FAIL  clean tree refused\n%s\n' "$out"
fi

refuses "badly formatted Swift" "lint: FAILED, swift format" \
    Sources/MeetingCaptureCore/Probe.swift 'let  probe=1'
refuses "badly formatted test" "lint: FAILED, swift format" \
    Tests/Probe.swift 'let  probe=3'
# shellcheck disable=SC2016  # the unquoted $1 is the seeded bug
refuses "shell bug in a script" "lint: FAILED, shellcheck" \
    .githooks/pre-commit "$(printf '#!/usr/bin/env bash\nrm -rf $1/x')"
refuses "broken workflow" "lint: FAILED, actionlint" \
    .github/workflows/ci.yml "$(printf 'name: CI\non: push\njobs:\n  a:\n    steps:\n      - run: echo')"
refuses "unpinned action" "not pinned" \
    .github/workflows/ci.yml "$(sed 's/- run: echo ok/- uses: actions\/checkout@v7/' .github/workflows/ci.yml)"

# ─── lint.sh --staged: judges the index, not the working copy ────────────────
reset_tree() { git reset -q --hard HEAD; git clean -qfd; }
BASE_GOOD='let probe = 1'

# $1 label. Passes when lint --staged exits 0.
staged_passes() {
    local out
    if out="$(scripts/lint.sh --staged 2>&1)"; then
        pass=$((pass+1)); printf '  ok    %s\n' "$1"
    else
        fail=$((fail+1)); printf '  FAIL  %s: refused\n%s\n' "$1" "$out"
    fi
}
# $1 label, $2 text the refusal must contain.
staged_refuses() {
    local out
    if out="$(scripts/lint.sh --staged 2>&1)"; then
        fail=$((fail+1)); printf '  FAIL  %s: lint passed\n' "$1"
    elif printf '%s' "$out" | grep -qF "$2"; then
        pass=$((pass+1)); printf '  ok    %s\n' "$1"
    else
        fail=$((fail+1)); printf '  FAIL  %s: refused for another reason\n%s\n' "$1" "$out"
    fi
}

# Staged bad, working copy good: refused, so the staged text is what's judged.
printf 'let  probe=1\n' > Sources/MeetingCaptureCore/Probe.swift
git add Sources/MeetingCaptureCore/Probe.swift
printf '%s\n' "$BASE_GOOD" > Sources/MeetingCaptureCore/Probe.swift
staged_refuses "staged bad Swift with a clean working copy" "lint: FAILED, swift format"
reset_tree

# Staged good, working copy bad: passes, the other direction of the same proof.
printf 'let probe = 11\n' > Sources/MeetingCaptureCore/Probe.swift
git add Sources/MeetingCaptureCore/Probe.swift
printf 'let  probe=1\n' > Sources/MeetingCaptureCore/Probe.swift
staged_passes "staged good Swift with a bad working copy"
reset_tree

# shellcheck disable=SC2016  # the unquoted $1 is the seeded bug
printf '#!/usr/bin/env bash\nrm -rf $1/x\n' > .githooks/pre-commit
git add .githooks/pre-commit
staged_refuses "staged shell bug" "lint: FAILED, shellcheck"
reset_tree

printf 'name: CI\non: push\njobs:\n  a:\n    steps:\n      - run: echo\n' > .github/workflows/ci.yml
git add .github/workflows/ci.yml
staged_refuses "staged broken workflow" "lint: FAILED, actionlint"
reset_tree

sed 's/- run: echo ok/- uses: actions\/checkout@v7/' .github/workflows/ci.yml > "$WORK/unpinned.yml"
cp "$WORK/unpinned.yml" .github/workflows/ci.yml
git add .github/workflows/ci.yml
staged_refuses "staged unpinned action" "not pinned"
reset_tree

# A bad file that isn't part of the commit doesn't refuse it.
printf 'let probe = 12\n' > Sources/MeetingCaptureCLI/Probe.swift
git add Sources/MeetingCaptureCLI/Probe.swift
printf 'let  probe=3\n' > Tests/Probe.swift
# shellcheck disable=SC2016  # the unquoted $1 is the seeded bug
printf '#!/usr/bin/env bash\nrm -rf $1/x\n' > scripts/unstaged.sh
staged_passes "unstaged bad files don't refuse"
reset_tree

# A staged deletion doesn't break it.
git rm -q Tests/Probe.swift
staged_passes "staged deleted Swift file"
reset_tree
git rm -q .githooks/pre-commit
staged_passes "staged deleted shell file"
reset_tree

# A name with a space is passed through whole, and still judged.
printf 'let probe = 5\n' > "Tests/My Probe.swift"
git add "Tests/My Probe.swift"
staged_passes "good Swift file with a space in its name"
printf 'let  probe=5\n' > "Tests/My Probe.swift"
git add "Tests/My Probe.swift"
staged_refuses "bad Swift file with a space in its name" "lint: FAILED, swift format"
reset_tree

# A staged .swift-format change makes it judge all Swift, even files not in the commit.
printf 'let  probe=3\n' > Tests/Probe.swift
git add Tests/Probe.swift
git commit -qm "test: committed bad format"
printf 'let probe = 13\n' > Sources/MeetingCaptureCLI/Probe.swift
git add Sources/MeetingCaptureCLI/Probe.swift
staged_passes "old bad Swift isn't judged when only other Swift is staged"
git reset -q --hard HEAD
printf '\n' >> .swift-format
git add .swift-format
staged_refuses "staged .swift-format change judges all Swift" "lint: FAILED, swift format"
git reset -q --hard HEAD~1
reset_tree

# Seconds, not minutes: a seeded refusal comes back well inside 15 s.
printf 'let  probe=1\n' > Sources/MeetingCaptureCore/Probe.swift
git add Sources/MeetingCaptureCore/Probe.swift
t0=$SECONDS
scripts/lint.sh --staged > /dev/null 2>&1
rc=$?
elapsed=$((SECONDS-t0))
if [ "$rc" -ne 0 ] && [ "$elapsed" -lt 15 ]; then
    pass=$((pass+1)); printf '  ok    staged refusal took %ss (under 15)\n' "$elapsed"
else
    fail=$((fail+1)); printf '  FAIL  staged refusal: exit %s after %ss\n' "$rc" "$elapsed"
fi
reset_tree

# A missing tool is a failure, not a skip.
mkdir "$WORK/bin"
for tool in git swift grep sed cat dirname basename mktemp rm perl env bash; do
    ln -s "$(command -v "$tool")" "$WORK/bin/$tool"
done
if out="$(PATH="$WORK/bin" scripts/lint.sh 2>&1)"; then
    fail=$((fail+1)); printf '  FAIL  missing tools: lint passed\n'
elif printf '%s' "$out" | grep -qF "shellcheck isn't installed"; then
    pass=$((pass+1)); printf '  ok    missing tool is a failure\n'
else
    fail=$((fail+1)); printf '  FAIL  missing tools: refused for another reason\n%s\n' "$out"
fi

printf 'let probe = 14\n' > Sources/MeetingCaptureCore/Probe.swift
git add Sources/MeetingCaptureCore/Probe.swift
if out="$(PATH="$WORK/bin" scripts/lint.sh --staged 2>&1)"; then
    fail=$((fail+1)); printf '  FAIL  missing tools, staged: lint passed\n'
elif printf '%s' "$out" | grep -qF "shellcheck isn't installed"; then
    pass=$((pass+1)); printf '  ok    missing tool is a failure in staged mode too\n'
else
    fail=$((fail+1)); printf '  FAIL  missing tools, staged: refused for another reason\n%s\n' "$out"
fi
reset_tree

printf '\nlint tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
