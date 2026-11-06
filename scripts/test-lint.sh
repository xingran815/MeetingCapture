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
git add -A

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

printf '\nlint tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
