#!/usr/bin/env bash
# --fast   build, unit tests, sweep of staged changes     (pre-commit, < 2 min)
# default  --fast + sweep and E2E tests + outgoing sweep  (pre-push, verifier, < 8 min)
# --live   default + small real calls, spends usage       (by hand only)
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

MODE="${1:-default}"
case "$MODE" in default|--fast|--live) ;; *) echo "usage: check.sh [--fast|--live]" >&2; exit 2 ;; esac

mkdir -p dev/tmp
step() { printf '\n== %s\n' "$1"; }
die()  { echo "check: FAILED at: $1" >&2; exit 1; }
START=$SECONDS

step "sweep: staged changes"
scripts/sweep.sh --staged || die "staged sweep"

step "lint"
scripts/lint.sh || die "lint"

step "build"
swift build 2>&1 | tail -3
[ "${PIPESTATUS[0]}" -eq 0 ] || die "swift build"

step "unit tests (fake CLIs first on PATH)"
PATH="$ROOT/Tests/FakeBin:$PATH" swift test 2>&1 | grep -E 'error:|Executed [0-9]+ tests' | tail -5
[ "${PIPESTATUS[0]}" -eq 0 ] || die "swift test"

if [ "$MODE" = "--fast" ]; then
    echo; echo "check --fast: passed in $((SECONDS-START))s"
    exit 0
fi

step "guard: tests without the fake CLIs must fail"
scripts/test-guard.sh || die "no-fake-CLI guard"

step "sweep: seeded leaks"
scripts/test-sweeps.sh | tail -1
[ "${PIPESTATUS[0]}" -eq 0 ] || die "seeded-leak tests"
scripts/test-sweeps-isolation.sh || die "seeded-leak tests left git's environment in place"
scripts/test-sweeps-isolation.sh "$ROOT/scripts/test-identity.sh" || die "identity tests left git's environment in place"
scripts/test-identity.sh | tail -1
[ "${PIPESTATUS[0]}" -eq 0 ] || die "identity tests"

step "lint: each tool catches a seeded mistake"
scripts/test-lint.sh | tail -1
[ "${PIPESTATUS[0]}" -eq 0 ] || die "lint tests"
scripts/test-sweeps-isolation.sh "$ROOT/scripts/test-lint.sh" || die "lint tests left git's environment in place"

step "sweep: everything outgoing"
scripts/sweep.sh --outgoing HEAD --not --remotes || die "outgoing sweep"
scripts/sweep.sh --tree || die "tree sweep"

step "E2E: transcribe a short fixture"
scripts/e2e.sh || die "E2E"

if [ "$MODE" = "--live" ]; then
    step "live"
    .build/debug/MeetingCaptureCLI --live-check || die "live check"
fi

echo; echo "check: passed in $((SECONDS-START))s"
