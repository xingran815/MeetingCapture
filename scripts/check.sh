#!/usr/bin/env bash
# --unit        build, unit tests                                    (every pre-push)
# --production  --unit + fake-CLI guard + short E2E                  (default; by judgment)
# --full        --production + e2e-full + sweep and lint self-tests  (before a milestone's final push)
# --live        --full + small real calls, spends usage              (by hand only)
#
# Lint and the sweeps aren't here, because the hooks run them. --full and --live
# save their commit and result in dev/tmp/check-full.txt, which the verifier reads
# instead of rerunning them.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

MODE="${1:---production}"
case "$MODE" in
    --unit|--production|--full|--live) ;;
    *) echo "usage: check.sh [--unit|--production|--full|--live]" >&2; exit 2 ;;
esac

mkdir -p dev/tmp
# shellcheck disable=SC1091  # lint runs shellcheck on each file alone
source scripts/timing.sh

step() { printf '\n== %s\n' "$1"; }
die()  { echo "check: FAILED at: $1" >&2; exit 1; }
START=$SECONDS

build() {
    swift build 2>&1 | tail -3
    return "${PIPESTATUS[0]}"
}

unit_tests() {
    PATH="$ROOT/Tests/FakeBin:$PATH" swift test 2>&1 | grep -E 'error:|Executed [0-9]+ tests' | tail -5
    return "${PIPESTATUS[0]}"
}

sweep_self_tests() {
    scripts/test-sweeps.sh | tail -1
    [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
    scripts/test-sweeps-isolation.sh || return 1
    scripts/test-sweeps-isolation.sh "$ROOT/scripts/test-identity.sh" || return 1
    scripts/test-identity.sh | tail -1
    [ "${PIPESTATUS[0]}" -eq 0 ]
}

lint_self_tests() {
    scripts/test-lint.sh | tail -1
    [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
    scripts/test-sweeps-isolation.sh "$ROOT/scripts/test-lint.sh" || return 1
    scripts/test-check-modes.sh | tail -1
    [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
    scripts/test-sweeps-isolation.sh "$ROOT/scripts/test-check-modes.sh"
}

# The commit, whether the tree matched it, and the result. A dirty tree means the
# result doesn't describe the commit, so the verifier has to treat it as no record.
save_full_record() {
    local rc=$? result=failed tree=clean
    [ "$rc" -eq 0 ] && result=passed
    [ -z "$(git status --porcelain)" ] || tree=dirty
    {
        printf 'commit %s\n' "$(git rev-parse HEAD)"
        printf 'tree %s\n' "$tree"
        printf 'mode %s\n' "$MODE"
        printf 'result %s\n' "$result"
        printf 'seconds %s\n' "$((SECONDS-START))"
    } > dev/tmp/check-full.txt
    exit "$rc"
}

case "$MODE" in
    --full|--live) trap save_full_record EXIT ;;
esac

step "build"
timed "build" build || die "swift build"

step "unit tests (fake CLIs first on PATH)"
timed "unit tests" unit_tests || die "swift test"

if [ "$MODE" != "--unit" ]; then
    step "guard: tests without the fake CLIs must fail"
    timed "guard" scripts/test-guard.sh || die "no-fake-CLI guard"

    step "E2E: transcribe a short fixture"
    timed "e2e" scripts/e2e.sh || die "E2E"
fi

if [ "$MODE" = "--full" ] || [ "$MODE" = "--live" ]; then
    step "E2E (full, local only): many cases, each reported by name"
    timed "e2e-full" scripts/e2e-full.sh || die "full E2E"

    step "sweep: seeded leaks"
    timed "sweep self-tests" sweep_self_tests || die "sweep self-tests"

    step "lint: each tool catches a seeded mistake"
    timed "lint self-tests" lint_self_tests || die "lint self-tests"
fi

if [ "$MODE" = "--live" ]; then
    step "live"
    timed "live" .build/debug/MeetingCaptureCLI --live-check || die "live check"
fi

timing_log "check $MODE total" "$((SECONDS-START))"
echo; echo "check $MODE: passed in $((SECONDS-START))s"
