#!/usr/bin/env bash
# Without the fake CLIs on PATH the test run must refuse to go on, so a test can
# never reach a real model.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2
mkdir -p dev/tmp

if swift test --filter FakeCLIGuardTests > dev/tmp/guard.log 2>&1; then
    echo "guard: FAILED, tests passed with no fake CLI on PATH; see dev/tmp/guard.log" >&2
    exit 1
fi
grep -q "is not the fake" dev/tmp/guard.log || {
    echo "guard: FAILED for another reason; see dev/tmp/guard.log" >&2
    exit 1
}
echo "guard: refused, as it should"
