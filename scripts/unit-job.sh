#!/usr/bin/env bash
# One job of check.sh's unit queue: runs the classes in <dir>/job<n>.classes through xctest
# on the bundle in UNIT_BUNDLE, logs to <dir>/job<n>.log, exit code beside it in .log.rc.
set -u
dir="$1"
n="$2"
log="$dir/job$n.log"
xcrun xctest -XCTest "$(cat "$dir/job$n.classes")" "$UNIT_BUNDLE" >"$log" 2>&1
echo $? >"$log.rc"
