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
cp "$SRC/scripts/check.sh" "$SRC/scripts/timing.sh" "$SRC/scripts/ci.sh" scripts/
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
for n in test-guard e2e e2e-full test-sweeps test-sweeps-isolation test-identity test-lint test-check-modes; do
    make_stub "scripts/$n.sh" "$n"
done
make_stub .build/debug/MeetingCaptureCLI MeetingCaptureCLI
make_stub scripts/identity.sh identity
# The stub test-check-modes.sh above stands in for this script, which check.sh
# runs; the real one never calls itself.
# These must never run from check.sh, so any call is traceable and fails.
make_stub scripts/lint.sh LINT-RAN
make_stub scripts/sweep.sh SWEEP-RAN
cat > "$WORK/bin/swift" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "stub swift ${STUB_SWIFT_VERSION:-1}"; exit 0; fi
line="swift $*"
echo "$line" >> "$STUB_TRACE"
echo "Executed 3 tests, key $SEED_SECRET at $SEED_PATH"
echo "noise $SEED_SECRET" >&2
if [ "${STUB_FAIL:-}" = "$line" ]; then
    echo "error: seeded failure" >&2
    exit 1
fi
exit 0
STUB
chmod +x "$WORK/bin/swift"
chmod +x scripts/*.sh
git add -A
git commit -qm "chore: base" || { echo "base commit failed"; exit 2; }

# Steps each mode must run, in order, as the stubs record them.
expected() {  # mode
    printf '%s\n' "swift build" "swift test"
    [ "$1" = "--unit" ] && return 0
    printf '%s\n' "test-guard" "e2e"
    [ "$1" = "--production" ] && return 0
    printf '%s\n' "e2e-full" "test-sweeps" "test-sweeps-isolation" \
        "test-sweeps-isolation test-identity.sh" "test-identity" \
        "test-lint" "test-sweeps-isolation test-lint.sh" \
        "test-check-modes" "test-sweeps-isolation test-check-modes.sh"
    [ "$1" = "--full" ] && return 0
    printf '%s\n' "MeetingCaptureCLI --live-check"
}

# The timing names each mode must log, in order.
expected_names() {  # mode
    printf '%s\n' "build" "unit tests"
    if [ "$1" != "--unit" ]; then printf '%s\n' "guard" "e2e"; fi
    if [ "$1" = "--full" ] || [ "$1" = "--live" ]; then
        printf '%s\n' "e2e-full" "sweep self-tests" "lint self-tests"
    fi
    if [ "$1" = "--live" ]; then printf '%s\n' "live"; fi
    printf '%s\n' "check $1 total"
}

FAIL=""; OUT=""; RC=0
# Runs check.sh with the stubs first on PATH and CI unset, unless EXTRA_ENV says otherwise.
run_check() {
    : > "$STUB_TRACE"
    OUT="$(env -u CI PATH="$WORK/bin:$PATH" STUB_FAIL="$FAIL" "$@" 2>&1)"
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
FAIL="swift test"; check_cmd --unit
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
    rm -f "$REC"; FAIL="swift test"; check_cmd "$mode"
    if [ -e "$REC" ]; then bad "failing $mode wrote a record"; else ok "failing $mode writes no record"; fi
done
FAIL=""

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
# ci.sh runs the unit tests with --skip "(names)$" (D-76); build that line from its own list,
# so the test follows the list and still catches a missing or malformed skip.
SKIPS="$(awk '/^CI_SKIPPED_TESTS=\(/{f=1;next} /^\)/{f=0} f{printf "%s%s", (n++?"|":""), $1}' scripts/ci.sh)"
if [ -n "$SKIPS" ]; then ok "ci.sh lists the tests CI skips"; else bad "ci.sh has no CI_SKIPPED_TESTS list"; fi
CI_SWIFT_TEST="swift test --skip ($SKIPS)\$"
printf '%s\n' "swift build" "swift build -c release" "$CI_SWIFT_TEST" "test-guard" \
    "SWEEP-RAN --tree" "SWEEP-RAN --outgoing $BASE..HEAD" "identity $BASE..HEAD" > "$WORK/main-want"
FAIL=""; ci_main "$BASE"
if [ "$RC" -ne 0 ]; then bad "ci.sh main failed with healthy stubs" "$OUT"
else same "Finding (M3.1): ci.sh main runs its seven steps in order" "$WORK/main-want"; fi
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
ci_main ""
if [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q "BASE_SHA isn't set"; then
    ok "Finding (M3.1): ci.sh main without BASE_SHA fails"
else bad "ci.sh main without BASE_SHA: exit $RC" "trace: $(cat "$STUB_TRACE")
$OUT"; fi

printf '\ncheck-modes tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
