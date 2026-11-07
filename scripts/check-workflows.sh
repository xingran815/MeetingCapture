#!/usr/bin/env bash
# Keeps the workflow rules true: actions pinned by full SHA, read-only permissions,
# no secrets or tokens, no privileged triggers, only the macos-26 runner, a time
# limit on every job, checkout of the PR head with no saved credentials, no .yaml
# file, and a cache restored only by ci.yml on PRs, because main's clean build is
# what later PRs reuse. Checks the copy of the repo it sits in, which is how
# lint.sh --staged judges a copy of the index.
# --self-test proves each rule goes red.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 2

# Prints one line per broken rule.
check_file() {
    local file="$1"
    grep -E "^[[:space:]-]*[\"']?uses[\"']?:" "$file" | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' > /dev/null \
        && echo "$file: action not pinned by full SHA"
    grep -qE 'pull_request_target|workflow_run' "$file" && echo "$file: privileged trigger"
    grep -qE 'secrets[.[]|github\.token' "$file" && echo "$file: uses a secret"
    grep -qE '^permissions:' "$file" || echo "$file: no top-level permissions"
    grep -qE '^[[:space:]]+contents: read' "$file" || echo "$file: contents isn't read-only"
    grep -qE '^[[:space:]]+[a-z-]+: write|write-all' "$file" && echo "$file: write permission"
    grep -E 'runs-on:' "$file" | grep -qvE 'runs-on:[[:space:]]+macos-26[[:space:]]*(#.*)?$' && echo "$file: runner isn't macos-26"
    local jobs limits
    jobs="$(grep -cE '^[[:space:]]+runs-on:' "$file")"
    limits="$(grep -cE '^[[:space:]]+timeout-minutes:' "$file")"
    [ "$jobs" -eq "$limits" ] || echo "$file: $jobs jobs but $limits time limits"
    # GitHub's merge ref carries its own identity and would trip the identity sweep.
    local checkouts heads creds
    checkouts="$(grep -cE 'uses:[[:space:]]+actions/checkout@' "$file")"
    heads="$(grep -cE '^[[:space:]]+ref:[[:space:]]+\$\{\{ env\.HEAD_SHA \}\}' "$file")"
    creds="$(grep -cE '^[[:space:]]+persist-credentials:[[:space:]]+false' "$file")"
    [ "$checkouts" -eq "$heads" ] || echo "$file: checkout isn't of the PR head"
    [ "$checkouts" -eq "$creds" ] || echo "$file: checkout keeps credentials"
    # Allowed rather than refused by trigger, because `on:` has too many spellings.
    # From the M3.1 reviews. Saving is fine; only restoring can feed main old objects.
    if grep -qE '/cache(/restore)?@' "$file"; then
        local text
        text="$(sed -E 's/(^|[[:space:]])#.*$//' "$file")"
        if [ "$(basename "$file")" != "ci.yml" ]; then
            echo "$file: restores a cache outside ci.yml"
        elif ! printf '%s\n' "$text" | grep -qw pull_request \
            || printf '%s\n' "$text" | grep -qwE 'push|release|schedule|workflow_dispatch|workflow_call|repository_dispatch'; then
            echo "$file: restores a cache on something other than a PR"
        fi
    fi
    return 0
}

check_dir() {
    local file
    for file in "$1"/*.yml; do
        [ -e "$file" ] && check_file "$file"
    done
    # GitHub runs these too, and every rule here would miss them.
    for file in "$1"/*.yaml; do
        [ -e "$file" ] && echo "$file: name it .yml so these rules see it"
    done
    return 0
}

if [ "${1:-}" = "--self-test" ]; then
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    # shellcheck disable=SC2016  # the text is meant literally
    good='on: push
permissions:
  contents: read
jobs:
  a:
    runs-on: macos-26
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7
        with:
          ref: ${{ env.HEAD_SHA }}
          persist-credentials: false'
    failed=0
    # Captures first: under pipefail, `| grep -q` can kill a command still printing,
    # and that reads as no match.
    says() {  # text command...
        local text="$1" out
        shift
        out="$("$@")"
        case "$out" in *"$text"*) return 0 ;; esac
        return 1
    }
    printf '%s\n' "$good" > "$work/ci.yml"
    if [ -n "$(check_file "$work/ci.yml")" ]; then echo "check-workflows: a good file was refused"; failed=1; fi
    # $1 reason expected, $2 sed expression that breaks the good file.
    expect() {
        printf '%s\n' "$good" | sed -E "$2" > "$work/ci.yml"
        if ! says "$1" check_file "$work/ci.yml"; then
            echo "check-workflows: didn't catch: $1"
            failed=1
        fi
    }
    expect "not pinned" 's/@[0-9a-f]+ # v7/@v7/'
    expect "privileged trigger" 's/^on: push/on: pull_request_target/'
    expect "privileged trigger" 's/^on: push/on: workflow_run/'
    # shellcheck disable=SC2016  # the text is meant literally
    expect "uses a secret" 's/macos-26/macos-26 # ${{ secrets.X }}/'
    expect "no top-level permissions" 's/^permissions:/perms:/'
    expect "read-only" 's/contents: read/contents: none/'
    expect "write permission" 's/contents: read/contents: read\n  issues: write/'
    # shellcheck disable=SC2016  # the text is meant literally
    expect "uses a secret" "s/macos-26/macos-26 # \${{ secrets['X'] }}/"
    # shellcheck disable=SC2016  # the text is meant literally
    expect "uses a secret" 's/macos-26/macos-26 # ${{ github.token }}/'
    expect "runner isn't" 's/macos-26/macos-26-xlarge/'
    expect "runner isn't" 's/macos-26/ubuntu-latest-4-cores/'
    # shellcheck disable=SC2016  # the text is meant literally
    expect "runner isn't" 's/macos-26/${{ vars.R }}/'
    expect "PR head" '/ref: /d'
    expect "keeps credentials" '/persist-credentials/d'
    expect "time limits" '/timeout-minutes/d'
    cache_step='      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6'
    restore_step='      - uses: actions/cache/restore@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6'
    save_step='      - uses: actions/cache/save@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6'
    # $1 what should catch it, $2 the on: line, $3 the step.
    cache_refused() {
        printf '%s\n%s\n' "$good" "$3" | sed -E "s/^on: push/$2/" > "$work/ci.yml"
        says "restores a cache" check_file "$work/ci.yml" || { echo "check-workflows: didn't catch a cache with: $1"; failed=1; }
    }
    cache_refused "on: push" "on: push" "$cache_step"
    cache_refused "a restore on push" "on: push" "$restore_step"
    cache_refused "a list" "on: [push, pull_request]" "$cache_step"
    cache_refused "a quoted key" '"on": push' "$cache_step"
    cache_refused "a mapping" "on: {push: {branches: [main]}}" "$cache_step"
    cache_refused "a release" "on: release" "$cache_step"
    cache_refused "a manual run" "on: workflow_dispatch" "$cache_step"
    printf '%s\n%s\n' "$good" "$cache_step" | sed -E 's/^on: push/on: pull_request/' > "$work/other.yml"
    says "outside ci.yml" check_file "$work/other.yml" || { echo "check-workflows: didn't catch a cache outside ci.yml"; failed=1; }
    rm -f "$work/other.yml"
    printf '%s\n%s\n' "$good" "$save_step" > "$work/ci.yml"
    if [ -n "$(check_file "$work/ci.yml")" ]; then echo "check-workflows: refused saving a cache on a push"; failed=1; fi
    printf '%s\n%s\n' "$good" "$cache_step" | sed -E 's/^on: push/on: pull_request/' > "$work/ci.yml"
    if [ -n "$(check_file "$work/ci.yml")" ]; then echo "check-workflows: refused a cache on a PR"; failed=1; fi
    printf '%s\n' "$good" | sed -E 's/^( *- )uses: actions\/checkout@[^ ]+.*/\1"uses": actions\/checkout@v7/' > "$work/ci.yml"
    says "not pinned" check_file "$work/ci.yml" || { echo "check-workflows: didn't catch an unpinned quoted uses"; failed=1; }
    printf '%s\n' "$good" > "$work/ci.yml"
    : > "$work/x.yaml"
    says "name it .yml" check_dir "$work" || { echo "check-workflows: didn't catch a .yaml file"; failed=1; }
    rm -f "$work/x.yaml"
    [ "$failed" -eq 0 ] && echo "check-workflows self-test: ok"
    exit "$failed"
fi

problems="$(check_dir .github/workflows)"
if [ -n "$problems" ]; then
    printf '%s\n' "$problems" >&2
    exit 1
fi
echo "workflows: ok"
