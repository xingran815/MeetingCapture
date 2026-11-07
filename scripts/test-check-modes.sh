#!/usr/bin/env bash
# Proves each check.sh mode runs the steps the M3.1 spec's table says, that a
# failure in any step stops it, and that timing and the --full record hold what
# they should. Runs in a throwaway repo with stubs for swift and every script
# check.sh calls, so nothing builds. Seeds are assembled at runtime so this file
# doesn't trip the sweep; every value is invented.
set -uo pipefail

# Clear git's repo variables before anything else (see test-sweeps.sh, M2.1).
while IFS= read -r var; do unset "$var"; done < <(git rev-parse --local-env-vars)

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

REPO="$WORK/repo"
git init -q -b main "$REPO"
cd "$REPO" || exit 2
if [ "$(git rev-parse --absolute-git-dir)" != "$(pwd -P)/.git" ]; then
    echo "test-check-modes: refusing to run, git isn't using the temporary repo." >&2
    exit 2
fi
git config user.name tester
git config user.email "1+tester@users.noreply.github.com"

export STUB_TRACE="$WORK/trace.log"
export SEED_SECRET="sk-""ant-api03-abcdefghijklmnopqrstuvwxyz012345"
export SEED_PATH="/Us""ers/someone/notes/call.txt"
: > "$STUB_TRACE"

mkdir -p scripts .build/debug "$WORK/bin"
cp "$SRC/scripts/check.sh" "$SRC/scripts/unit-job.sh" "$SRC/scripts/timing.sh" "$SRC/scripts/ci.sh" scripts/
printf 'dev/tmp/\n' > .gitignore
printf '{"pins": [], "version": 3}\n' > Package.resolved

# A stub records "<name> <args, basenames only>", prints secret-looking output,
# and fails when STUB_FAIL equals that exact line.
make_stub() {  # file name
    cat > "$1" <<STUB
#!/usr/bin/env bash
line="$2"
for a in "\$@"; do line="\$line \${a##*/}"; done
echo "\$line" >> "\$STUB_TRACE"
echo "\$line|\$PATH" >> "\${STUB_PATHS:-/dev/null}"
# Like the real sweep.sh and identity.sh, which exit 2 on an empty range. ci.sh
# itself carries on after a failed \$(range), so that is what stops it.
for a in "\$@"; do [ -n "\$a" ] || { echo "bad range" >&2; exit 2; }; done
echo "Executed 3 tests, key \$SEED_SECRET at \$SEED_PATH"
echo "noise \$SEED_SECRET" >&2
# A case can make one step change the repo, to see the record notice it.
if [ -n "\${STUB_HOOK:-}" ] && [ "\${STUB_HOOK_LINE:-}" = "\$line" ]; then eval "\$STUB_HOOK"; fi
if [ "\${STUB_FAIL:-}" = "\$line" ]; then
    echo "error: seeded failure" >&2
    exit 1
fi
exit 0
STUB
    chmod +x "$1"
}
for n in test-guard e2e e2e-full test-sweeps test-sweeps-isolation test-identity test-lint test-check-modes live-report; do
    make_stub "scripts/$n.sh" "$n"
done
make_stub .build/debug/MeetingCaptureCLI MeetingCaptureCLI
make_stub scripts/identity.sh identity
# The stub test-check-modes.sh above stands in for this script, which check.sh
# runs; the real one never calls itself.
# These must never run from check.sh, so any call is traceable and fails.
make_stub scripts/lint.sh LINT-RAN
make_stub scripts/sweep.sh SWEEP-RAN
# Invented tests: 2 + 1 in two slow classes, 3 in two ordinary classes, 1 in a serial class.
export DEFAULT_LIST="MeetingCaptureCoreTests.EchoRemoverSlowTests/testAlpha
MeetingCaptureCoreTests.EchoRemoverSlowTests/testBeta
MeetingCaptureCoreTests.EchoPipelineSlowTests/testZeta
MeetingCaptureCoreTests.WavTests/testGamma
MeetingCaptureCoreTests.ConfigTests/testDelta
MeetingCaptureCoreTests.ConfigTests/testEpsilon
MeetingCaptureCoreTests.DiskSerialTests/testSigma"
# The ordinary classes go in two jobs (1st, 3rd... and 2nd, 4th...) that start first, then each slow class is
# its own job (sorted by name), and a serial class runs last, alone.
PIPECLS="MeetingCaptureCoreTests.EchoPipelineSlowTests"
REMCLS="MeetingCaptureCoreTests.EchoRemoverSlowTests"
FAST1="MeetingCaptureCoreTests.ConfigTests"   # the ordinary classes alternate over two jobs that start first
FAST2="MeetingCaptureCoreTests.WavTests"
SERCLS="MeetingCaptureCoreTests.DiskSerialTests"
BUNDLE="FakePackageTests.xctest"
export XC_DIR="$WORK/xc"
mkdir -p "$XC_DIR" .build/debug/$BUNDLE
echo placeholder > .build/debug/$BUNDLE/Info.plist
cat > "$WORK/bin/swift" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "stub swift ${STUB_SWIFT_VERSION:-1}"; exit 0; fi
line="swift $*"
echo "$line" >> "$STUB_TRACE"
echo "$line|$PATH" >> "${STUB_PATHS:-/dev/null}"
# `swift test list` prints only the listed tests (the unit step counts lines with a slash).
if [ "${1:-}" = "test" ] && [ "${2:-}" = "list" ]; then
    if [ "${STUB_FAIL:-}" = "$line" ]; then echo "error: seeded failure" >&2; exit 1; fi
    [ -n "${STUB_LIST_EMPTY:-}" ] && exit 0
    printf '%s\n' "${STUB_LIST:-$DEFAULT_LIST}"
    exit 0
fi
n="${STUB_CI_N:-4}"; w=tests; [ "$n" = 1 ] && w=test   # xctest says "1 test"
echo "Executed $n $w, key $SEED_SECRET at $SEED_PATH"
echo "noise $SEED_SECRET" >&2
if [ "${STUB_FAIL:-}" = "$line" ]; then
    echo "error: seeded failure" >&2
    exit 1
fi
exit 0
STUB
chmod +x "$WORK/bin/swift"
# xcrun xctest -XCTest <classes> <bundle>. Each run reports as many tests as the listing holds
# for its classes (XC_DELTA_FOR / XC_DELTA skew one job's count; XC_FAIL=<text in the classes>
# fails the jobs whose classes contain it). A job waits for the trace line of the job before
# it, so the trace order is fixed: the two ordinary jobs, pipeline slow, remover slow. It records
# start and end events and how many runs were live at its start (XC_SLEEP keeps a run live).
cat > "$WORK/bin/xcrun" <<'STUB'
#!/usr/bin/env bash
line="xcrun"
for a in "$@"; do line="$line ${a##*/}"; done
LIST="${STUB_LIST:-$DEFAULT_LIST}"
mkdir -p "$XC_DIR"
dep=""
case "$3" in
    *.WavTests) dep="MeetingCaptureCoreTests.ConfigTests" ;;
    *EchoPipelineSlowTests) dep="MeetingCaptureCoreTests.WavTests" ;;
    *EchoRemoverSlowTests) dep="MeetingCaptureCoreTests.EchoPipelineSlowTests" ;;
esac
if [ -n "$dep" ] && printf '%s\n' "$LIST" | grep -qF "$dep/"; then
    for _ in $(seq 100); do grep -qxF "xcrun xctest -XCTest $dep ${4##*/}" "$STUB_TRACE" && break; sleep 0.05; done
fi
n="$(printf '%s\n' "$LIST" | awk -v c="$3" 'BEGIN{split(c,a,",");for(i in a)w[a[i]]=1} {split($0,p,"/"); if(p[1] in w)k++} END{print k+0}')"
if [ -n "${XC_DELTA_FOR:-}" ]; then case "$3" in *"$XC_DELTA_FOR"*) n=$((n + XC_DELTA)) ;; esac; fi
echo "$line" >> "$STUB_TRACE"
echo "$line|$PATH" >> "${STUB_PATHS:-/dev/null}"
touch "$XC_DIR/run.$$"
echo "$3 $(ls "$XC_DIR" | grep -c '^run\.')" >> "$XC_DIR/counts"
echo "start $3" >> "$XC_DIR/events"
[ -n "${XC_SLEEP:-}" ] && sleep "$XC_SLEEP"
echo "end $3" >> "$XC_DIR/events"
rm -f "$XC_DIR/run.$$"
echo "Test Suite 'X' passed. Executed 1 test, with 0 failures (0 unexpected)"
echo "noise $SEED_SECRET at $SEED_PATH" >&2
if { [ -n "${XC_FAIL:-}" ] && case "$3" in *"$XC_FAIL"*) true ;; *) false ;; esac; } || [ "${STUB_FAIL:-}" = "$line" ]; then
    echo "error: -[X testBad] : seeded failure" >&2
    w=tests; [ "$n" = 1 ] && w=test
    echo "Executed $n $w, with 1 failures (1 unexpected)"
    exit 1
fi
w=tests; [ "$n" = 1 ] && w=test   # real xctest prints "Executed 1 test," for a single test
echo "Executed $n $w, with 0 failures (0 unexpected) in 0.1 (0.1) seconds"
exit 0
STUB
chmod +x "$WORK/bin/xcrun"
chmod +x scripts/*.sh
git add -A
git commit -qm "chore: base" || { echo "base commit failed"; exit 2; }

# Steps each mode must run, in order, as the stubs record them.
expected() {  # mode
    printf '%s\n' "swift build" "swift build --build-tests" "swift test list --skip-build" \
        "xcrun xctest -XCTest $FAST1 $BUNDLE" "xcrun xctest -XCTest $FAST2 $BUNDLE" \
        "xcrun xctest -XCTest $PIPECLS $BUNDLE" "xcrun xctest -XCTest $REMCLS $BUNDLE" \
        "xcrun xctest -XCTest $SERCLS $BUNDLE"
    [ "$1" = "--unit" ] && return 0
    printf '%s\n' "test-guard" "e2e"
    [ "$1" = "--production" ] && return 0
    printf '%s\n' "e2e-full" "test-sweeps" "test-sweeps-isolation" \
        "test-sweeps-isolation test-identity.sh" "test-identity" \
        "test-lint" "test-sweeps-isolation test-lint.sh" \
        "test-check-modes" "test-sweeps-isolation test-check-modes.sh"
    [ "$1" = "--full" ] && return 0
    printf '%s\n' "MeetingCaptureCLI --live-check" "live-report"
}

# The timing names each mode must log, in order.
expected_names() {  # mode
    printf '%s\n' "build" "unit tests"
    if [ "$1" != "--unit" ]; then printf '%s\n' "guard" "e2e"; fi
    if [ "$1" = "--full" ] || [ "$1" = "--live" ]; then
        printf '%s\n' "e2e-full" "sweep self-tests" "lint self-tests"
    fi
    if [ "$1" = "--live" ]; then printf '%s\n' "live" "live report"; fi
    printf '%s\n' "check $1 total"
}

FAIL=""; OUT=""; RC=0
T_W=2
# Runs check.sh with the stubs first on PATH and CI unset, unless EXTRA_ENV says otherwise.
run_check() {
    : > "$STUB_TRACE"
    # The cases were written for 2 workers; T_W="" (empty) leaves UNIT_WORKERS unset to get check.sh's default.
    OUT="$(env -u CI -u UNIT_WORKERS ${T_W:+UNIT_WORKERS=$T_W} PATH="$WORK/bin:$PATH" STUB_FAIL="$FAIL" "$@" 2>&1)"
    RC=$?
}
check_cmd() { run_check scripts/check.sh "$@"; }

same() {  # label wanted-file
    if [ "$(cat "$STUB_TRACE")" = "$(cat "$2")" ]; then ok "$1"
    else bad "$1" "wanted:
$(cat "$2")
got:
$(cat "$STUB_TRACE")"; fi
}

# ─── Step lists ──────────────────────────────────────────────────────────────
for mode in --unit --production --full --live; do
    expected "$mode" > "$WORK/want"
    FAIL=""; check_cmd "$mode"
    if [ "$RC" -ne 0 ]; then bad "$mode passes with healthy stubs" "$OUT"; continue; fi
    same "$mode runs its listed steps, in order" "$WORK/want"
    if grep -qxE 'LINT-RAN.*|SWEEP-RAN.*' "$STUB_TRACE"; then bad "$mode ran lint.sh or sweep.sh"
    else ok "$mode doesn't run lint.sh or sweep.sh"; fi
done

# Finding (M3.2 --full): unit_tests put Tests/FakeBin on PATH in the calling shell, so the
# no-fake-CLI guard ran with the fake CLIs and failed. The stubs record their PATH; the unit
# step's stubs must see FakeBin and the guard's stub must not. Matched on the last path part,
# since the temporary repo's own path is in every PATH entry.
export STUB_PATHS="$WORK/paths.log"
path_has_fakebin() {  # line-prefix: 0 when every recorded line with that prefix has FakeBin on PATH
    local found=1 l
    while IFS= read -r l; do
        found=0
        case ":${l#*|}:" in *"/Tests/FakeBin:"*) ;; *) return 1 ;; esac
    done < <(grep -F "$1" "$STUB_PATHS")
    return "$found"
}
path_lacks_fakebin() {  # line-prefix: 0 when at least one such line exists and none has FakeBin
    local found=1 l
    while IFS= read -r l; do
        found=0
        case ":${l#*|}:" in *"/Tests/FakeBin:"*) return 1 ;; esac
    done < <(grep -F "$1" "$STUB_PATHS")
    return "$found"
}
for mode in --production --full; do
    : > "$STUB_PATHS"; FAIL=""; check_cmd "$mode"
    if [ "$RC" -ne 0 ]; then bad "Finding (M3.2 --full): check.sh $mode failed with healthy stubs" "$OUT"; continue; fi
    if path_has_fakebin "swift build --build-tests" && path_has_fakebin "xcrun xctest"; then
        ok "Finding (M3.2 --full): check.sh $mode's unit step sees Tests/FakeBin on PATH"
    else bad "check.sh $mode: the unit step's stubs didn't see Tests/FakeBin" "$(cat "$STUB_PATHS")"; fi
    if path_lacks_fakebin "test-guard|"; then
        ok "Finding (M3.2 --full): check.sh $mode runs the guard without Tests/FakeBin on PATH"
    else bad "check.sh $mode: the guard ran with Tests/FakeBin on PATH (or didn't run)" "$(cat "$STUB_PATHS")"; fi
done

expected --production > "$WORK/want"
FAIL=""; check_cmd
if [ "$RC" -eq 0 ]; then same "plain check.sh equals --production" "$WORK/want"; else bad "plain check.sh failed" "$OUT"; fi

# ─── Bad flags ───────────────────────────────────────────────────────────────
for flag in --fast --bogus -x --Unit; do
    rm -f dev/tmp/check-full.txt
    FAIL=""; check_cmd "$flag"
    if [ "$RC" -eq 2 ] && [ ! -s "$STUB_TRACE" ] && [ ! -e dev/tmp/check-full.txt ]; then
        ok "$flag exits 2 and runs nothing"
    else
        bad "$flag: exit $RC, trace '$(cat "$STUB_TRACE")'" "$OUT"
    fi
done

# ─── A seeded failure in each step stops the mode ────────────────────────────
for mode in --unit --production --full --live; do
    expected "$mode" > "$WORK/exp"
    cp "$WORK/exp" "$WORK/steps"
    i=0
    while IFS= read -r line; do
        i=$((i+1))
        head -n "$i" "$WORK/exp" > "$WORK/want"
        # The xctest jobs are a queue, so one failing still lets every other job run (then the step fails).
        case "$line" in xcrun*) head -n "$(grep -n '^xcrun' "$WORK/exp" | tail -1 | cut -d: -f1)" "$WORK/exp" > "$WORK/want" ;; esac
        FAIL="$line"; check_cmd "$mode"
        if [ "$RC" -eq 0 ]; then
            bad "$mode: failing '$line' still exited 0" "$OUT"
        elif [ "$(cat "$STUB_TRACE")" != "$(cat "$WORK/want")" ]; then
            bad "$mode: failing '$line' didn't stop the run" "got:
$(cat "$STUB_TRACE")"
        elif printf '%s' "$OUT" | grep -q 'passed in'; then
            bad "$mode: failing '$line' still printed a pass" "$OUT"
        else
            ok "$mode stops at failing '$line'"
        fi
    done < "$WORK/steps"
done
FAIL=""

# ─── Timing: names and seconds only ──────────────────────────────────────────
for mode in --unit --production --full --live; do
    rm -f dev/tmp/timing.log
    FAIL=""; check_cmd "$mode"
    log=dev/tmp/timing.log
    if [ ! -f "$log" ]; then bad "$mode wrote no dev/tmp/timing.log"; continue; fi
    expected_names "$mode" > "$WORK/names"
    sed 's/ [0-9][0-9]*$//' "$log" > "$WORK/got-names"
    if [ "$(cat "$WORK/names")" = "$(cat "$WORK/got-names")" ]; then ok "$mode timing log has one line per step"
    else bad "$mode timing names differ" "$(cat "$log")"; fi
    if grep -qvE '^[a-z][a-z0-9 -]* [0-9]+$' "$log"; then bad "$mode timing log has a line that isn't '<name> <seconds>'" "$(cat "$log")"
    else ok "$mode timing lines are only '<name> <seconds>'"; fi
    if grep -qF "$SEED_SECRET" "$log" || grep -qF "$SEED_PATH" "$log" || grep -q 'sk-\|/Users' "$log"; then
        bad "$mode: stub output reached the timing log"
    else ok "$mode: secret-looking output isn't in the timing log"; fi
done

# A failed step is timed too, and still logs only a name and seconds.
rm -f dev/tmp/timing.log
FAIL="xcrun xctest -XCTest $FAST1 $BUNDLE"; check_cmd --unit
if [ "$(sed 's/ [0-9][0-9]*$//' dev/tmp/timing.log)" = "$(printf '%s\n' "build" "unit tests")" ] \
    && ! grep -qvE '^[a-z][a-z0-9 -]* [0-9]+$' dev/tmp/timing.log; then
    ok "a failed run logs its steps as names and seconds"
else bad "failed-run timing log wrong" "$(cat dev/tmp/timing.log 2>/dev/null)"; fi
FAIL=""

# On CI the log is the job's own: no file, and the lines show on stdout.
rm -f dev/tmp/timing.log
: > "$STUB_TRACE"
OUT="$(CI=1 PATH="$WORK/bin:$PATH" STUB_FAIL="" scripts/check.sh --unit 2>&1)"; RC=$?
if [ "$RC" -ne 0 ]; then bad "CI run failed" "$OUT"
elif [ -e dev/tmp/timing.log ]; then bad "CI=1 still wrote dev/tmp/timing.log"
elif printf '%s\n' "$OUT" | grep -qE '^timing: build [0-9]+s$' \
    && printf '%s\n' "$OUT" | grep -qE '^timing: unit tests [0-9]+s$' \
    && printf '%s\n' "$OUT" | grep -qE '^timing: check --unit total [0-9]+s$'; then
    ok "CI=1 writes no file and shows 'timing: name Ns' on stdout"
else bad "CI=1 timing lines missing from stdout" "$OUT"; fi
if printf '%s' "$OUT" | grep -F "$SEED_SECRET" | grep -q '^timing:'; then bad "CI timing line carried stub output"
else ok "CI timing lines carry no stub output"; fi

# ─── The --full / --live record ──────────────────────────────────────────────
REC=dev/tmp/check-full.txt
record_has() {  # label line...
    local label="$1" l; shift
    for l in "$@"; do
        if ! grep -qxF "$l" "$REC"; then bad "$label: record lacks '$l'" "$(cat "$REC" 2>/dev/null)"; return; fi
    done
    ok "$label"
}

HEAD_SHA="$(git rev-parse HEAD)"
for mode in --full --live; do
    rm -f "$REC"; FAIL=""; check_cmd "$mode"
    if [ ! -f "$REC" ]; then bad "$mode wrote no record"; continue; fi
    record_has "$mode records commit, clean tree and passed" "commit $HEAD_SHA" "tree clean" "result passed" "mode $mode"
    if grep -qE '^seconds [0-9]+$' "$REC"; then ok "$mode record has seconds"; else bad "$mode record lacks seconds" "$(cat "$REC")"; fi
done

rm -f "$REC"; FAIL="e2e-full"; check_cmd --full
record_has "failing --full records result failed" "commit $HEAD_SHA" "tree clean" "result failed"
rm -f "$REC"; FAIL="swift build"; check_cmd --full
record_has "--full failing at the first step records result failed" "result failed"
rm -f "$REC"; FAIL="MeetingCaptureCLI --live-check"; check_cmd --live
record_has "failing --live records result failed" "mode --live" "result failed"
rm -f "$REC"; FAIL="live-report"; check_cmd --live
record_has "M4 live report step: a failing live-report.sh stops --live with result failed" "mode --live" "result failed"

# An untracked file, then a changed tracked file, each make the record say dirty.
FAIL=""
printf 'x\n' > stray.txt
rm -f "$REC"; check_cmd --full
record_has "untracked file records tree dirty" "tree dirty" "result passed"
rm -f stray.txt
printf '# changed\n' >> scripts/e2e.sh
rm -f "$REC"; check_cmd --full
record_has "changed tracked file records tree dirty" "tree dirty" "result passed"
git checkout -q -- scripts/e2e.sh
rm -f "$REC"; check_cmd --full
record_has "tree is clean again after the cleanup" "tree clean"

# Finding (M3.1): the record must name the commit the run STARTED on, and call the
# tree dirty if HEAD moved or the tree was dirty at either end.
FAIL=""
export STUB_HOOK_LINE="e2e-full" STUB_HOOK='git commit -q --allow-empty -m "test: mid-run"'
rm -f "$REC"; check_cmd --full
unset STUB_HOOK_LINE STUB_HOOK
record_has "Finding (M3.1): a commit made mid-run records the start sha and tree dirty" \
    "commit $HEAD_SHA" "tree dirty" "result passed"
git reset -q --hard "$HEAD_SHA"

printf 'x\n' > stray.txt
export STUB_HOOK_LINE="e2e-full" STUB_HOOK='rm -f stray.txt'
rm -f "$REC"; check_cmd --full
unset STUB_HOOK_LINE STUB_HOOK
if [ -z "$(git status --porcelain)" ]; then ok "the stub cleaned the tree by the end"; else bad "tree still dirty after the stub"; fi
record_has "Finding (M3.1): a tree dirty at the start but clean at the end records tree dirty" \
    "commit $HEAD_SHA" "tree dirty"
rm -f stray.txt

# Finding (M3.1): a tree that becomes dirty only at the end counts too.
export STUB_HOOK_LINE="e2e-full" STUB_HOOK='printf late > late.txt'
rm -f "$REC"; check_cmd --full
unset STUB_HOOK_LINE STUB_HOOK
record_has "Finding (M3.1): a tree dirtied during the run records tree dirty" "tree dirty"
rm -f late.txt
rm -f "$REC"; check_cmd --full
record_has "an untouched clean run still records tree clean" "commit $HEAD_SHA" "tree clean"

for mode in --unit --production; do
    rm -f "$REC"; FAIL=""; check_cmd "$mode"
    if [ -e "$REC" ]; then bad "$mode wrote a record"; else ok "$mode writes no record"; fi
    rm -f "$REC"; FAIL="xcrun xctest -XCTest $FAST1 $BUNDLE"; check_cmd "$mode"
    if [ -e "$REC" ]; then bad "failing $mode wrote a record"; else ok "failing $mode writes no record"; fi
done
FAIL=""

# ─── The unit step: a queue of xctest jobs, every test counted (D-77) ────────
unit_fails() {  # label wanted-message-or-empty
    if [ "$RC" -eq 0 ]; then bad "$1: exited 0" "$OUT"
    elif [ -n "${2:-}" ] && ! printf '%s' "$OUT" | grep -qF "$2"; then bad "$1: exit $RC but no '$2'" "$OUT"
    elif printf '%s' "$OUT" | grep -q 'passed in'; then bad "$1: printed a pass" "$OUT"
    else ok "$1"; fi
}
xc_line() { printf 'xcrun xctest -XCTest %s %s' "$1" "$BUNDLE"; }

# Each slow class is its own job; every other class shares one; a serial class is its own job after them.
FAIL=""; check_cmd --unit
if [ "$RC" -ne 0 ]; then bad "the unit step passes with healthy stubs" "$OUT"; fi
for cls in "$FAST1" "$FAST2" "$PIPECLS" "$REMCLS" "$SERCLS"; do
    if [ "$(grep -cxF "$(xc_line "$cls")" "$STUB_TRACE")" = 1 ]; then ok "xctest job for exactly: $cls"
    else bad "no single xctest job for $cls" "$(cat "$STUB_TRACE")"; fi
done
if [ "$(grep -c '^xcrun' "$STUB_TRACE")" = 5 ] \
    && ! grep -E '^xcrun' "$STUB_TRACE" | grep -E 'SlowTests.*,|,.*SlowTests|SerialTests.*,|,.*SerialTests'; then
    ok "slow and serial classes are never grouped with another class (5 jobs from 5 classes)"
else bad "slow/serial classes were grouped" "$(cat "$STUB_TRACE")"; fi
FAIL=""; STUB_LIST="MeetingCaptureCoreTests.AaaTests/t1
MeetingCaptureCoreTests.BbbTests/t2
MeetingCaptureCoreTests.CccTests/t3
MeetingCaptureCoreTests.DddTests/t4
MeetingCaptureCoreTests.EeeTests/t5" run_check scripts/check.sh --unit
if [ "$RC" -eq 0 ] && [ "$(grep -c '^xcrun' "$STUB_TRACE")" = 2 ] \
    && grep -qxF "$(xc_line "MeetingCaptureCoreTests.AaaTests,MeetingCaptureCoreTests.CccTests,MeetingCaptureCoreTests.EeeTests")" "$STUB_TRACE" \
    && grep -qxF "$(xc_line "MeetingCaptureCoreTests.BbbTests,MeetingCaptureCoreTests.DddTests")" "$STUB_TRACE"; then
    ok "the ordinary classes alternate over two jobs (1st, 3rd, 5th and 2nd, 4th)"
else bad "ordinary classes not split in two alternating jobs: rc $RC" "$(cat "$STUB_TRACE")"; fi
FAIL=""; check_cmd --unit
if [ -f dev/tmp/unit/job1.log ] && [ -f dev/tmp/unit/job5.log ] && [ ! -e dev/tmp/unit/job6.log ] && [ ! -e dev/tmp/unit-slow.log ]; then
    ok "each job logs to dev/tmp/unit/job<n>.log"
else bad "unit job logs wrong" "$(ls dev/tmp dev/tmp/unit 2>&1)"; fi
if printf '%s\n' "$OUT" | grep -qxF "unit: ran 7 of 7 tests in 5 jobs on 2 workers"; then ok "the unit step prints the count line"
else bad "count line missing" "$OUT"; fi

# Biggest first: the two ordinary jobs are queued before the slow classes; at most 2 jobs at once;
# the serial class starts only after every queued job has ended, and runs alone.
rm -rf "$XC_DIR"; mkdir -p "$XC_DIR"
FAIL=""; XC_SLEEP=0.3 run_check scripts/check.sh --unit
if [ "$RC" -ne 0 ]; then bad "the unit step passes with slow stubs" "$OUT"; fi
if [ "$(grep -E '^xcrun' "$STUB_TRACE" | sed -n 1,2p)" = "$(xc_line "$FAST1")
$(xc_line "$FAST2")" ] && [ "$(grep -E '^xcrun' "$STUB_TRACE" | sed -n 3p)" = "$(xc_line "$PIPECLS")" ]; then ok "the two ordinary jobs start first, then the slow classes"
else bad "queue order wrong" "$(cat "$STUB_TRACE")"; fi
max="$(awk '{print $NF}' "$XC_DIR/counts" | sort -n | tail -1)"
if [ "$max" = 2 ]; then ok "two jobs run at once, never more"; else bad "most jobs live at once was '$max', wanted 2" "$(cat "$XC_DIR/counts")"; fi
lastend="$(grep -n '^end ' "$XC_DIR/events" | grep -vF "$SERCLS" | tail -1 | cut -d: -f1)"
serstart="$(grep -nF "start $SERCLS" "$XC_DIR/events" | cut -d: -f1)"
if [ -n "$lastend" ] && [ -n "$serstart" ] && [ "$serstart" -gt "$lastend" ] && [ "$(grep -F "$SERCLS" "$XC_DIR/counts" | awk '{print $2}')" = 1 ]; then
    ok "the serial class starts after the queue is done and runs alone"
else bad "serial class not run alone after the queue" "$(cat "$XC_DIR/events")"; fi
rm -rf "$XC_DIR"; mkdir -p "$XC_DIR"
FAIL=""; XC_SLEEP=0.3 STUB_LIST="MeetingCaptureCoreTests.WavTests/testGamma
MeetingCaptureCoreTests.ConfigTests/testDelta
MeetingCaptureCoreTests.EchoRemoverSlowTests/testAlpha
MeetingCaptureCoreTests.EchoPipelineSlowTests/testZeta
MeetingCaptureCoreTests.AaaSlowTests/testOne
MeetingCaptureCoreTests.BbbSlowTests/testTwo" run_check scripts/check.sh --unit
max="$(awk '{print $NF}' "$XC_DIR/counts" | sort -n | tail -1)"
if [ "$RC" -eq 0 ] && [ "$max" = 2 ] && [ "$(grep -c '^xcrun' "$STUB_TRACE")" = 6 ]; then ok "with 6 jobs queued, still at most 2 run at once"
else bad "6 jobs: rc $RC, most live at once '$max'" "$OUT"; fi
rm -rf "$XC_DIR"; mkdir -p "$XC_DIR"

# A failure in any job fails the step; every other job still runs; the failed log is named.
for cls in "$PIPECLS" "$FAST1" "$SERCLS"; do
    FAIL=""; XC_FAIL="${cls##*.}" run_check scripts/check.sh --unit
    unit_fails "a failure in the job for ${cls##*.} fails check.sh --unit" "unit: FAILED in job"
    if [ "$(grep -c '^xcrun' "$STUB_TRACE")" = 5 ]; then ok "a failure in ${cls##*.} still lets the other jobs run"
    else bad "jobs missing after ${cls##*.} failed" "$(cat "$STUB_TRACE")"; fi
done
FAIL=""; XC_FAIL="${REMCLS##*.}" run_check scripts/check.sh --production
unit_fails "a slow-class failure fails --production and stops before the guard"
if grep -qxF test-guard "$STUB_TRACE"; then bad "guard ran after a unit failure"; else ok "nothing after the unit step runs when a job fails"; fi
FAIL=""; XC_FAIL=Tests run_check scripts/check.sh --unit
unit_fails "every job failing fails the step" "unit: FAILED in job"

# The counts must add up to the listing: a job that ran fewer or more tests, or a total that differs.
FAIL=""; XC_DELTA_FOR=ConfigTests XC_DELTA=-1 run_check scripts/check.sh --unit
unit_fails "a count mismatch (ordinary job ran one test fewer) fails" "unit: ran 6 tests of 7 listed"
FAIL=""; XC_DELTA_FOR=EchoPipelineSlowTests XC_DELTA=-1 run_check scripts/check.sh --unit
unit_fails "a count mismatch (a slow job ran none) fails" "unit: ran 6 tests of 7 listed"
FAIL=""; XC_DELTA_FOR=DiskSerialTests XC_DELTA=2 run_check scripts/check.sh --unit
unit_fails "a count mismatch (serial job ran more than listed) fails" "unit: ran 9 tests of 7 listed"
FAIL=""; XC_DELTA_FOR=EchoRemoverSlowTests XC_DELTA=1 run_check scripts/check.sh --unit
unit_fails "a count mismatch (more run than listed) fails" "unit: ran 8 tests of 7 listed"

# Odd listings.
FAIL=""; STUB_LIST_EMPTY=1 run_check scripts/check.sh --unit
unit_fails "no tests listed fails" "couldn't list the tests"
if grep -q '^xcrun' "$STUB_TRACE"; then bad "xctest ran with no tests listed"; else ok "no xctest run when nothing was listed"; fi
FAIL="swift test list --skip-build"; check_cmd --unit
unit_fails "a failing test listing fails" "couldn't list the tests"
FAIL=""
mv ".build/debug/$BUNDLE" "$WORK/bundle.keep"
check_cmd --unit
unit_fails "a missing test bundle fails" "couldn't list the tests"
mv "$WORK/bundle.keep" ".build/debug/$BUNDLE"
FAIL=""; STUB_LIST="MeetingCaptureCoreTests.EchoRemoverSlowTests/testAlpha
MeetingCaptureCoreTests.EchoPipelineSlowTests/testZeta" run_check scripts/check.sh --unit
if [ "$RC" -eq 0 ] && [ "$(grep -c '^xcrun' "$STUB_TRACE")" = 2 ] && printf '%s\n' "$OUT" | grep -qF "ran 2 of 2 tests in 2 jobs"; then
    ok "a listing of only slow classes runs just their jobs"
else bad "only-slow listing: rc $RC" "$OUT"; fi
FAIL=""; STUB_LIST="MeetingCaptureCoreTests.WavTests/testGamma
MeetingCaptureCoreTests.ConfigTests/testDelta" run_check scripts/check.sh --unit
if [ "$RC" -eq 0 ] && [ "$(grep -c '^xcrun' "$STUB_TRACE")" = 2 ] && grep -qxF "$(xc_line "$FAST1")" "$STUB_TRACE" \
    && grep -qxF "$(xc_line "$FAST2")" "$STUB_TRACE"; then
    ok "a listing with no slow or serial class runs just the two ordinary jobs"
else bad "only-ordinary listing: rc $RC" "$OUT"; fi

# Finding (M3.2 post-listen review): class names with digits or underscores were not parsed, so such a
# class was never listed, run or counted. A digit class (M4AArchiveTests) runs, and its tests count.
FAIL=""; STUB_LIST="MeetingCaptureCoreTests.M4AArchiveTests/testOne
MeetingCaptureCoreTests.M4AArchiveTests/testTwo
MeetingCaptureCoreTests.Echo_2SlowTests/testThree
MeetingCaptureCoreTests.WavTests/testGamma" run_check scripts/check.sh --unit
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qF "unit: ran 4 of 4 tests in 3 jobs" \
    && grep -E '^xcrun' "$STUB_TRACE" | grep -qF "MeetingCaptureCoreTests.M4AArchiveTests" \
    && grep -qxF "$(xc_line "MeetingCaptureCoreTests.Echo_2SlowTests")" "$STUB_TRACE"; then
    ok "a class name with a digit or underscore (M4AArchiveTests, Echo_2SlowTests) is run and counted"
else bad "digit/underscore class names: rc $RC" "$OUT
$(cat "$STUB_TRACE")"; fi

# Bug 1: .build/debug is a symlink to the real folder holding the bundle; the bundle is still found.
mv .build/debug .build/real-debug && ln -s real-debug .build/debug
FAIL=""; check_cmd --unit
if [ "$RC" -eq 0 ] && [ "$(grep -c '^xcrun' "$STUB_TRACE")" = 5 ]; then ok "the bundle is found when .build/debug is a symlink to a real folder"
else bad "symlinked .build/debug: rc $RC" "$OUT"; fi
rm .build/debug && mv .build/real-debug .build/debug

# Bug 2: a job with one test prints "Executed 1 test," (singular); it is counted.
FAIL=""; STUB_LIST="MeetingCaptureCoreTests.EchoRemoverSlowTests/testAlpha
MeetingCaptureCoreTests.WavTests/testGamma" run_check scripts/check.sh --unit
if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qxF "unit: ran 2 of 2 tests in 2 jobs on 2 workers" \
    && grep -q 'Executed 1 test,' dev/tmp/unit/job1.log && ! grep -q 'Executed 1 tests' dev/tmp/unit/job1.log; then
    ok "check.sh counts a job whose xctest prints 'Executed 1 test,' (singular)"
else bad "singular 'Executed 1 test' not counted: rc $RC" "$OUT"; fi

# Worker counts: the default is 4, UNIT_WORKERS overrides it; the ordinary classes split one job per
# worker (class i goes to job (i-1) % workers) and the count line names the workers.
LIST6="MeetingCaptureCoreTests.AaaTests/t1
MeetingCaptureCoreTests.BbbTests/t2
MeetingCaptureCoreTests.CccTests/t3
MeetingCaptureCoreTests.DddTests/t4
MeetingCaptureCoreTests.EeeTests/t5
MeetingCaptureCoreTests.FffTests/t6
MeetingCaptureCoreTests.GggSlowTests/t7"
for w in "" 3; do
    label="${w:-default}"; want="${w:-4}"
    rm -rf "$XC_DIR"; mkdir -p "$XC_DIR"
    FAIL=""; T_W="$w" XC_SLEEP=0.3 STUB_LIST="$LIST6" run_check scripts/check.sh --unit
    max="$(awk '{print $NF}' "$XC_DIR/counts" | sort -n | tail -1)"
    nfast="$(grep -E '^xcrun' "$STUB_TRACE" | grep -vc 'SlowTests')"
    if [ "$RC" -eq 0 ] && [ "$max" = "$want" ] && [ "$nfast" = "$want" ]; then ok "$label workers: at most $want jobs live at once, the ordinary classes split $want ways"
    else bad "$label workers: rc $RC, most live '$max', ordinary jobs '$nfast' (wanted $want)" "$(cat "$STUB_TRACE")"; fi
    if printf '%s\n' "$OUT" | grep -qxF "unit: ran 7 of 7 tests in $((want + 1)) jobs on $want workers"; then ok "$label workers: the count line says $want workers"
    else bad "$label workers: count line wrong" "$OUT"; fi
done
# Class i goes to job (i-1) % workers: with 4 workers, A and E share job 1; the others have one each.
rm -rf "$XC_DIR"; mkdir -p "$XC_DIR"
FAIL=""; T_W="" STUB_LIST="$LIST6" run_check scripts/check.sh --unit
if grep -qxF "$(xc_line "MeetingCaptureCoreTests.AaaTests,MeetingCaptureCoreTests.EeeTests")" "$STUB_TRACE" \
    && grep -qxF "$(xc_line "MeetingCaptureCoreTests.BbbTests,MeetingCaptureCoreTests.FffTests")" "$STUB_TRACE" \
    && grep -qxF "$(xc_line "MeetingCaptureCoreTests.CccTests")" "$STUB_TRACE" \
    && grep -qxF "$(xc_line "MeetingCaptureCoreTests.DddTests")" "$STUB_TRACE"; then
    ok "with 4 workers class i goes to job (i-1) % 4"
else bad "4-way split wrong" "$(cat "$STUB_TRACE")"; fi
rm -rf "$XC_DIR"; mkdir -p "$XC_DIR"

FAIL="swift build --build-tests"; check_cmd --unit
unit_fails "a build failure (swift build --build-tests) fails check.sh --unit"
if grep -qE '^(swift test list|xcrun)' "$STUB_TRACE"; then bad "tests ran after a failed test build"; else ok "a failed test build runs no tests"; fi
FAIL=""
check_cmd --unit
if [ "$RC" -eq 0 ]; then ok "the unit step passes again with healthy stubs"; else bad "unit step stuck failing" "$OUT"; fi

# ─── CI wiring: ci.sh cache-id ───────────────────────────────────────────────
cache_id() { env -u CI PATH="$WORK/bin:$PATH" STUB_SWIFT_VERSION="${1:-1}" scripts/ci.sh cache-id 2>&1; }
id1="$(cache_id)"
if [ "$(printf '%s\n' "$id1" | wc -l | tr -d ' ')" = "1" ] && printf '%s' "$id1" | grep -qE '^id=[0-9a-f]{16}$'; then
    ok "cache-id prints exactly one id=<16 hex> line"
else bad "cache-id output wrong" "$id1"; fi
if [ "$(cache_id)" = "$id1" ]; then ok "cache-id is stable for the same inputs"; else bad "cache-id changed with no input change"; fi
printf '{"pins": [{"identity": "probe"}], "version": 3}\n' > Package.resolved
id2="$(cache_id)"
if printf '%s' "$id2" | grep -qE '^id=[0-9a-f]{16}$' && [ "$id2" != "$id1" ]; then ok "cache-id changes when Package.resolved changes"
else bad "cache-id didn't change with Package.resolved" "$id1 / $id2"; fi
if [ "$(cache_id 2)" != "$id2" ]; then ok "cache-id changes with the compiler version"; else bad "cache-id ignored the compiler version"; fi
git checkout -q -- Package.resolved

# Finding (M3.1): cache-id dies when Package.resolved is missing, rather than
# hashing the compiler version alone.
mv Package.resolved "$WORK/resolved.keep"
out="$(cache_id)"; rc=$?
if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^id=' && printf '%s' "$out" | grep -q 'Package.resolved is missing'; then
    ok "Finding (M3.1): cache-id fails when Package.resolved is missing"
else bad "cache-id with no Package.resolved: exit $rc" "$out"; fi
mv "$WORK/resolved.keep" Package.resolved

# Finding (M3.1): ci.sh main had no test. Its steps, in order; a failure at each
# stops it; no BASE_SHA fails. The sweep and identity stubs trace as SWEEP-RAN and identity.
ci_main() {  # base-sha-or-empty
    : > "$STUB_TRACE"
    if [ -n "$1" ]; then
        OUT="$(env -u CI PATH="$WORK/bin:$PATH" STUB_FAIL="$FAIL" BASE_SHA="$1" scripts/ci.sh main 2>&1)"
    else
        OUT="$(env -u CI -u BASE_SHA PATH="$WORK/bin:$PATH" STUB_FAIL="$FAIL" scripts/ci.sh main 2>&1)"
    fi
    RC=$?
}
BASE="$(git rev-parse HEAD)"
# ci.sh lists the tests, then runs everything but the classes named `…SlowTests` (D-77).
CI_SWIFT_TEST="swift test --skip-build --skip SlowTests/"
printf '%s\n' "swift build" "swift build -c release" "swift build --build-tests" "swift test list --skip-build" \
    "$CI_SWIFT_TEST" "test-guard" \
    "SWEEP-RAN --tree" "SWEEP-RAN --outgoing $BASE..HEAD" "identity $BASE..HEAD" > "$WORK/main-want"
FAIL=""; ci_main "$BASE"
if [ "$RC" -ne 0 ]; then bad "ci.sh main failed with healthy stubs" "$OUT"
else same "Finding (M3.1): ci.sh main runs its steps in order, skipping SlowTests/" "$WORK/main-want"; fi
cp "$WORK/main-want" "$WORK/main-steps"
i=0
while IFS= read -r line; do
    i=$((i+1))
    head -n "$i" "$WORK/main-want" > "$WORK/want"
    FAIL="$line"; ci_main "$BASE"
    if [ "$RC" -eq 0 ]; then bad "ci.sh main: failing '$line' still exited 0" "$OUT"
    elif [ "$(cat "$STUB_TRACE")" != "$(cat "$WORK/want")" ]; then bad "ci.sh main: failing '$line' didn't stop the run" "$(cat "$STUB_TRACE")"
    else ok "ci.sh main stops at failing '$line'"; fi
done < "$WORK/main-steps"
FAIL=""
# CI's count check: the run must equal the listed tests that aren't in a …SlowTests class (4 of 7 here).
ci_main "$BASE"
if [ "$RC" -eq 0 ] && [ "$(grep -c 'SlowTests/' "$STUB_TRACE")" = 1 ] && ! grep -q 'xcrun' "$STUB_TRACE"; then
    ok "ci.sh skips by class name with --skip SlowTests/ and runs no xctest job"
else bad "ci.sh unit line wrong" "$(cat "$STUB_TRACE")"; fi
for n in 3 5 0; do
    STUB_CI_N=$n ci_main "$BASE"
    if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF "ci: ran $n unit tests, expected 4" && ! grep -qx 'test-guard' "$STUB_TRACE"; then
        ok "ci.sh fails when it ran $n unit tests but 4 are listed outside SlowTests"
    else bad "ci.sh count check with $n: exit $RC" "$OUT"; fi
done
STUB_LIST_EMPTY=1 ci_main "$BASE"
if [ "$RC" -ne 0 ] && ! grep -qx 'test-guard' "$STUB_TRACE" && printf '%s' "$OUT" | grep -qF "ci: no unit tests listed"; then ok "ci.sh fails on an empty test listing"
else bad "ci.sh on an empty listing: exit $RC" "$OUT"; fi
STUB_LIST_EMPTY=1 STUB_CI_N=0 ci_main "$BASE"
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -qF "ci: no unit tests listed"; then ok "ci.sh fails on an empty listing even when 0 tests ran"
else bad "ci.sh passed on an empty listing with 0 run: exit $RC" "$OUT"; fi
STUB_LIST="MeetingCaptureCoreTests.EchoRemoverSlowTests/testAlpha
MeetingCaptureCoreTests.WavTests/testGamma" STUB_CI_N=1 ci_main "$BASE"
if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'ci: ran'; then ok "ci.sh counts a run that prints 'Executed 1 test,' (singular)"
else bad "ci.sh missed the singular 'Executed 1 test' line: exit $RC" "$OUT"; fi
STUB_LIST="MeetingCaptureCoreTests.EchoRemoverSlowTests/testAlpha
MeetingCaptureCoreTests.WavTests/testGamma" STUB_CI_N=1 ci_main "$BASE"
if [ "$RC" -eq 0 ]; then ok "ci.sh counts only the tests outside SlowTests (1 of 2)"; else bad "ci.sh miscounted a mixed listing" "$OUT"; fi
STUB_LIST="MeetingCaptureCoreTests.EchoRemoverSlowTests/testAlpha
MeetingCaptureCoreTests.WavTests/testGamma" STUB_CI_N=2 ci_main "$BASE"
if [ "$RC" -ne 0 ]; then ok "ci.sh fails when a slow test seems to have run (2 run, 1 expected)"; else bad "ci.sh accepted a slow test running" "$OUT"; fi
ci_main ""
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "BASE_SHA isn't set"; then
    ok "Finding (M3.1): ci.sh main without BASE_SHA fails"
else bad "ci.sh main without BASE_SHA: exit $RC" "trace: $(cat "$STUB_TRACE")
$OUT"; fi

# Finding (M3.2 --full): the same for ci.sh's test job.
: > "$STUB_PATHS"; FAIL=""; ci_main "$BASE"
if [ "$RC" -ne 0 ]; then bad "Finding (M3.2 --full): ci.sh main failed with healthy stubs" "$OUT"
else
    if path_has_fakebin "swift test --skip-build"; then ok "Finding (M3.2 --full): ci.sh's unit step sees Tests/FakeBin on PATH"
    else bad "ci.sh: the unit step didn't see Tests/FakeBin" "$(cat "$STUB_PATHS")"; fi
    if path_lacks_fakebin "test-guard|"; then ok "Finding (M3.2 --full): ci.sh runs the guard without Tests/FakeBin on PATH"
    else bad "ci.sh: the guard ran with Tests/FakeBin on PATH (or didn't run)" "$(cat "$STUB_PATHS")"; fi
fi

printf '\ncheck-modes tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
