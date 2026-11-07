#!/usr/bin/env bash
# Sourced by check.sh and ci.sh. Logs step names and seconds and nothing else:
# locally to dev/tmp/timing.log, which is gitignored, and on CI to the job log.
# Step names are literals in those scripts, so no path or value can reach the log.

timing_log() {  # name seconds
    printf 'timing: %s %ss\n' "$1" "$2"
    if [ -z "${CI:-}" ]; then
        printf '%s %s\n' "$1" "$2" >> dev/tmp/timing.log
    fi
}

timed() {  # name command...
    local name="$1" start=$SECONDS rc=0
    shift
    "$@" || rc=$?
    timing_log "$name" "$((SECONDS-start))"
    return "$rc"
}
