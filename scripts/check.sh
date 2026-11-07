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

# Classes run on a queue of UNIT_WORKERS workers, biggest jobs first: each class named
# `…SlowTests` is its own job, all other classes share one job, and a class named
# `…SerialTests` runs alone after the queue, for a test that can't share the machine. A test
# may run in parallel when it uses its own temp folder, no fixed path and no real config
# (D-77). The bundle is run through xctest, because a second `swift test` waits on SwiftPM's
# lock on .build. The counts must add up to the listed total, so no test drops out unseen.
# 4 by default, the user's choice: 135 s at a 2.0 GB peak, against 216 s and 1.6 GB on 2
# (D-79). UNIT_WORKERS overrides it. The ordinary classes split into
# as many jobs as there are workers.
UNIT_WORKERS="${UNIT_WORKERS:-4}"
unit_job() { "$ROOT/scripts/unit-job.sh" "$@"; }
# A subshell, so the fake CLIs on PATH never reach the guard that must run without them.
unit_tests() (
    local bundle listed classes slow fast serial dir job i ran want failed
    export PATH="$ROOT/Tests/FakeBin:$PATH"
    swift build --build-tests 2>&1 | grep -E 'error:' | tail -5
    [ "${PIPESTATUS[0]}" -eq 0 ] || return 1
    bundle="$(find -H "$ROOT/.build/debug" -maxdepth 1 -name '*PackageTests.xctest' | head -1)"
    listed="$(swift test list --skip-build 2>/dev/null)" || { echo "unit: couldn't list the tests"; return 1; }
    classes="$(printf '%s\n' "$listed" | sed -n 's/^\([A-Za-z]*Tests\.[A-Za-z]*\)\/.*/\1/p' | sort -u)"
    [ -n "$classes" ] && [ -d "$bundle" ] || { echo "unit: couldn't list the tests"; return 1; }
    slow="$(printf '%s\n' "$classes" | grep -E 'SlowTests$' || true)"
    serial="$(printf '%s\n' "$classes" | grep -E 'SerialTests$' || true)"
    # The ordinary classes, split in one job per worker that start first: together they're the biggest
    # share, and starting them last left one worker idle at the end.
    fast="$(printf '%s\n' "$classes" | grep -vE '(Slow|Serial)Tests$' || true)"
    local k parts=""
    for ((k = 0; k < UNIT_WORKERS; k++)); do
        parts="$parts $(printf '%s\n' "$fast" | awk -v w="$UNIT_WORKERS" -v k="$k" 'NF && (NR - 1) % w == k' | paste -sd, -)"
    done
    fast="$parts"
    dir="$ROOT/dev/tmp/unit"
    rm -rf "$dir" && mkdir -p "$dir"
    i=0
    for job in $fast $slow; do  # class names hold no spaces
        i=$((i + 1))
        printf '%s' "$job" >"$dir/job$i.classes"
    done
    export UNIT_BUNDLE="$bundle"
    seq 1 "$i" | xargs -P "$UNIT_WORKERS" -I {} "$ROOT/scripts/unit-job.sh" "$dir" {}
    for job in $serial; do
        i=$((i + 1))
        printf '%s' "$job" >"$dir/job$i.classes"
        unit_job "$dir" "$i"
    done
    grep -hE 'error: -\[' "$dir"/*.log 2>/dev/null | head -10
    ran=0
    failed=0
    for f in "$dir"/*.log; do
        [ -e "$f" ] || continue
        local n last
        last="$(grep -E 'Executed [0-9]+ tests?' "$f" | tail -1)"
        n="$(printf '%s' "$last" | sed -E 's/.*Executed ([0-9]+) tests?.*/\1/')"
        ran=$((ran + ${n:-0}))
        [ "$(cat "$f.rc" 2>/dev/null)" = 0 ] || { failed=1; echo "unit: FAILED in $(basename "$f"): $last"; }
    done
    want="$(printf '%s\n' "$listed" | grep -c '/')"
    echo "unit: ran $ran of $want tests in $i jobs on $UNIT_WORKERS workers"
    [ "$ran" -eq "$want" ] || { echo "unit: ran $ran tests of $want listed"; return 1; }
    [ "$failed" -eq 0 ]
)

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
