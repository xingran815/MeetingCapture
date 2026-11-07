#!/usr/bin/env bash
# One entry per CI job, so the workflows hold no logic and every job can be run
# here too. BASE_SHA is the commit before the first one being checked; it's the
# PR's base, or the previous tip on a push to main.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2
mkdir -p dev/tmp
# shellcheck disable=SC1091  # lint runs shellcheck on each file alone
source scripts/timing.sh

die() { echo "ci: FAILED: $1" >&2; exit 1; }

range() {
    [ -n "${BASE_SHA:-}" ] || die "BASE_SHA isn't set"
    git cat-file -e "$BASE_SHA^{commit}" || die "BASE_SHA isn't in this checkout"
    printf '%s..HEAD\n' "$BASE_SHA"
}

unit_tests() { PATH="$ROOT/Tests/FakeBin:$PATH" swift test; }

build_and_test() {
    timed "debug build" swift build || die "debug build"
    timed "release build" swift build -c release || die "release build"
    timed "unit tests" unit_tests || die "unit tests"
    timed "guard" scripts/test-guard.sh || die "no-fake-CLI guard"
}

case "${1:-}" in
    test)
        build_and_test
        ;;
    leaks)
        timed "sweep self-tests" scripts/test-sweeps.sh || die "seeded-leak tests"
        timed "sweep isolation" scripts/test-sweeps-isolation.sh || die "seeded-leak tests left git's environment in place"
        timed "check-mode self-tests" scripts/test-check-modes.sh || die "check-mode tests"
        timed "tree sweep" scripts/sweep.sh --tree || die "tree sweep"
        commits="$(range)" || exit 1
        timed "commit sweep" scripts/sweep.sh --outgoing "$commits" || die "sweep of these commits"
        ;;
    identity)
        timed "identity self-test" scripts/test-identity.sh || die "identity check self-test"
        commits="$(range)" || exit 1
        timed "identity" scripts/identity.sh "$commits" || die "commit identity"
        ;;
    lint)
        if [ -n "${CI:-}" ]; then
            timed "lint tools" brew install shellcheck actionlint || die "installing the lint tools"
        fi
        timed "lint" scripts/lint.sh || die "lint"
        timed "lint self-tests" scripts/test-lint.sh || die "lint tests"
        ;;
    deps)
        timed "resolve" swift package resolve || die "swift package resolve"
        git diff --exit-code Package.resolved || die "Package.resolved doesn't match Package.swift"
        ;;
    fresh)
        timed "setup" scripts/setup.sh || die "setup.sh"
        [ "$(git config core.hooksPath)" = ".githooks" ] || die "setup.sh didn't install the hooks"
        for hook in pre-commit commit-msg pre-push; do
            [ -x ".githooks/$hook" ] || die "$hook isn't executable after setup"
        done
        echo "fresh clone: hooks installed"
        ;;
    e2e)
        start=$SECONDS
        folder="$(scripts/ci-fetch-model.sh)" || die "fetching the model"
        timing_log "fetch model" "$((SECONDS-start))"
        timed "debug build" swift build || die "debug build"
        E2E_MODEL="openai_whisper-tiny" E2E_MODEL_FOLDER="$folder" timed "e2e" scripts/e2e.sh || die "E2E"
        ;;
    main)
        # The push to main: a clean build, unit tests, then the real sweeps. The PR
        # already ran their self-tests. The workflow then saves this build as the
        # cache for later PRs, so it must never start from a cache itself.
        commits="$(range)" || exit 1
        build_and_test
        timed "tree sweep" scripts/sweep.sh --tree || die "tree sweep"
        timed "commit sweep" scripts/sweep.sh --outgoing "$commits" || die "sweep of these commits"
        timed "identity" scripts/identity.sh "$commits" || die "commit identity"
        ;;
    cache-id)
        # Goes in the build cache's key, so a new compiler or changed dependencies
        # start clean instead of mixing with old objects. Prints a GITHUB_OUTPUT line.
        [ -f Package.resolved ] || die "Package.resolved is missing"
        id="$({ swift --version 2>&1; cat Package.resolved; } | shasum -a 256 | cut -c1-16)"
        printf 'id=%s\n' "$id"
        ;;
    *)
        echo "usage: ci.sh test|leaks|identity|lint|deps|fresh|e2e|main|cache-id" >&2
        exit 2
        ;;
esac
