#!/usr/bin/env bash
# The one lint, used by check.sh and CI. shellcheck and actionlint may be missing
# on a dev Mac, where they're skipped out loud. On CI a missing tool is a failure.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2
failed=0

# Sources/Speexdsp is vendored, so it isn't ours to format.
if ! swift format lint --strict --recursive Package.swift Sources/MeetingCaptureCore Sources/MeetingCaptureCLI Tests; then
    echo "lint: FAILED, swift format. Fix with: swift format -i -r Package.swift Sources/MeetingCaptureCore Sources/MeetingCaptureCLI Tests" >&2
    failed=1
fi

missing() {
    if [ -n "${CI:-}" ]; then
        echo "lint: FAILED, $1 isn't installed on CI." >&2
        failed=1
    else
        echo "lint: skipped $1, not installed here. CI runs it."
    fi
}

if command -v shellcheck > /dev/null; then
    shellcheck scripts/*.sh .githooks/* || { echo "lint: FAILED, shellcheck." >&2; failed=1; }
else
    missing shellcheck
fi

if command -v actionlint > /dev/null; then
    actionlint || { echo "lint: FAILED, actionlint." >&2; failed=1; }
else
    missing actionlint
fi

scripts/check-workflows.sh --self-test || failed=1
scripts/check-workflows.sh || failed=1

[ "$failed" -eq 0 ] && echo "lint: ok"
exit "$failed"
