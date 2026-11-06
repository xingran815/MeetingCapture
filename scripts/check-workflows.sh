#!/usr/bin/env bash
# Keeps the workflow rules true: actions pinned by full SHA, read-only permissions,
# no secrets, no pull_request_target, standard runners, a time limit on every job.
# --self-test proves each rule goes red.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

# Prints one line per broken rule.
check_file() {
    local file="$1"
    grep -E '^[[:space:]-]*uses:' "$file" | grep -vE '@[0-9a-f]{40}([[:space:]]|$)' > /dev/null \
        && echo "$file: action not pinned by full SHA"
    grep -q 'pull_request_target' "$file" && echo "$file: pull_request_target"
    grep -q 'secrets\.' "$file" && echo "$file: uses a secret"
    grep -qE '^permissions:' "$file" || echo "$file: no top-level permissions"
    grep -qE '^[[:space:]]+contents: read' "$file" || echo "$file: contents isn't read-only"
    grep -qE '^[[:space:]]+[a-z-]+: write|write-all' "$file" && echo "$file: write permission"
    grep -E 'runs-on:' "$file" | grep -qE -- '-(large|xlarge)' && echo "$file: paid runner"
    local jobs limits
    jobs="$(grep -cE '^[[:space:]]+runs-on:' "$file")"
    limits="$(grep -cE '^[[:space:]]+timeout-minutes:' "$file")"
    [ "$jobs" -eq "$limits" ] || echo "$file: $jobs jobs but $limits time limits"
    return 0
}

check_dir() {
    local file
    for file in "$1"/*.yml; do
        [ -e "$file" ] && check_file "$file"
    done
    return 0
}

if [ "${1:-}" = "--self-test" ]; then
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    good='on: push
permissions:
  contents: read
jobs:
  a:
    runs-on: macos-26
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7'
    failed=0
    printf '%s\n' "$good" > "$work/ci.yml"
    if [ -n "$(check_file "$work/ci.yml")" ]; then echo "check-workflows: a good file was refused"; failed=1; fi
    # $1 reason expected, $2 sed expression that breaks the good file.
    expect() {
        printf '%s\n' "$good" | sed -E "$2" > "$work/ci.yml"
        if ! check_file "$work/ci.yml" | grep -qF "$1"; then
            echo "check-workflows: didn't catch: $1"
            failed=1
        fi
    }
    expect "not pinned" 's/@[0-9a-f]+ # v7/@v7/'
    expect "pull_request_target" 's/^on: push/on: pull_request_target/'
    # shellcheck disable=SC2016  # the text is meant literally
    expect "uses a secret" 's/macos-26/macos-26 # ${{ secrets.X }}/'
    expect "no top-level permissions" 's/^permissions:/perms:/'
    expect "read-only" 's/contents: read/contents: none/'
    expect "write permission" 's/contents: read/contents: read\n  issues: write/'
    expect "paid runner" 's/macos-26/macos-26-xlarge/'
    expect "time limits" '/timeout-minutes/d'
    [ "$failed" -eq 0 ] && echo "check-workflows self-test: ok"
    exit "$failed"
fi

problems="$(check_dir .github/workflows)"
if [ -n "$problems" ]; then
    printf '%s\n' "$problems" >&2
    exit 1
fi
echo "workflows: ok"
