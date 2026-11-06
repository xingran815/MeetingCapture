#!/usr/bin/env bash
# The one lint, used by check.sh, the pre-commit hook and CI. Every tool is
# required, so a local pass means the same as a CI pass.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2
failed=0

for tool in shellcheck actionlint; do
    if ! command -v "$tool" > /dev/null; then
        echo "lint: FAILED, $tool isn't installed. Run: brew install shellcheck actionlint" >&2
        failed=1
    fi
done

# Sources/Speexdsp is vendored, so it isn't ours to format.
if ! swift format lint --strict --recursive Package.swift Sources/MeetingCaptureCore Sources/MeetingCaptureCLI Tests; then
    echo "lint: FAILED, swift format. Fix with: swift format -i -r Package.swift Sources/MeetingCaptureCore Sources/MeetingCaptureCLI Tests" >&2
    failed=1
fi

if command -v shellcheck > /dev/null; then
    shellcheck scripts/*.sh .githooks/* || { echo "lint: FAILED, shellcheck." >&2; failed=1; }
fi

if command -v actionlint > /dev/null; then
    actionlint || { echo "lint: FAILED, actionlint." >&2; failed=1; }
fi

scripts/check-workflows.sh --self-test || failed=1
scripts/check-workflows.sh || failed=1

[ "$failed" -eq 0 ] && echo "lint: ok"
exit "$failed"
