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

# Two groups at once, each serial: the slow echo remover class, and every other class.
# No test shares state with another (temp folders are per test, and all 584 passed under
# `--parallel`), but two jobs is the memory limit. The test bundle is run directly,
# because a second `swift test` waits on SwiftPM's lock on .build. About 225 s instead
# of 390 s. The counts must add up to the listed total, so no test can drop out unseen.
SLOW_CLASS=MeetingCaptureCoreTests.EchoRemoverTests
unit_tests() {
    local bundle listed rest a b ea eb ran
    export PATH="$ROOT/Tests/FakeBin:$PATH"
    swift build --build-tests 2>&1 | grep -E 'error:' | tail -5
    [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
    bundle="$(find "$ROOT/.build/debug" -maxdepth 1 -name '*PackageTests.xctest' | head -1)"
    listed="$(swift test list --skip-build 2>/dev/null)"
    rest="$(printf '%s\n' "$listed" | sed -n 's/^\([A-Za-z]*Tests\.[A-Za-z]*\)\/.*/\1/p' | sort -u \
        | grep -vx "$SLOW_CLASS" | paste -sd, -)"
    [ -n "$rest" ] && [ -d "$bundle" ] || { echo "unit: couldn't list the tests"; return 1; }
    a="$ROOT/dev/tmp/unit-slow.log"
    b="$ROOT/dev/tmp/unit-rest.log"
    xcrun xctest -XCTest "$SLOW_CLASS" "$bundle" >"$a" 2>&1 &
    local pa=$!
    xcrun xctest -XCTest "$rest" "$bundle" >"$b" 2>&1 &
    local pb=$!
    wait "$pa"; ea=$?
    wait "$pb"; eb=$?
    grep -hE 'error: -\[' "$a" "$b" | head -10
    ran=0
    for f in "$a" "$b"; do
        local n last
        last="$(grep -E 'Executed [0-9]+ tests' "$f" | tail -1)"
        echo "$(basename "$f" .log):$last"
        n="$(printf '%s' "$last" | sed -E 's/.*Executed ([0-9]+) tests.*/\1/')"
        ran=$((ran + ${n:-0}))
    done
    local want
    want="$(printf '%s\n' "$listed" | grep -c '/')"
    [ "$ran" -eq "$want" ] || { echo "unit: ran $ran tests of $want listed"; return 1; }
    [ "$ea" -eq 0 ] && [ "$eb" -eq 0 ]
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

# The commit the run started on, whether the tree matched it, and the result. A
# run takes minutes, so the tree counts as dirty if it was dirty at either end or
# HEAD moved. Dirty means the result doesn't describe the commit, so the verifier
# has to treat it as no record. From the M3.1 review.
START_HEAD="$(git rev-parse HEAD)"
START_STATUS="$(git status --porcelain)"
save_full_record() {
    local rc=$? result=failed tree=clean
    [ "$rc" -eq 0 ] && result=passed
    if [ -n "$START_STATUS" ] || [ -n "$(git status --porcelain)" ] \
        || [ "$(git rev-parse HEAD)" != "$START_HEAD" ]; then
        tree=dirty
    fi
    {
        printf 'commit %s\n' "$START_HEAD"
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
