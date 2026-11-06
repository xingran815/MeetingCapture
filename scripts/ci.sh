#!/usr/bin/env bash
# One entry per CI job, so the workflow holds no logic and every job can be run
# here too. BASE_SHA is the commit before the first one being checked; it's the
# PR's base, or the previous tip on a push to main.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2
mkdir -p dev/tmp

die() { echo "ci: FAILED: $1" >&2; exit 1; }

range() {
    [ -n "${BASE_SHA:-}" ] || die "BASE_SHA isn't set"
    git cat-file -e "$BASE_SHA^{commit}" || die "BASE_SHA isn't in this checkout"
    printf '%s..HEAD\n' "$BASE_SHA"
}

case "${1:-}" in
    test)
        swift build || die "debug build"
        swift build -c release || die "release build"
        PATH="$ROOT/Tests/FakeBin:$PATH" swift test || die "unit tests"
        scripts/test-guard.sh || die "no-fake-CLI guard"
        ;;
    leaks)
        scripts/test-sweeps.sh || die "seeded-leak tests"
        scripts/test-sweeps-isolation.sh || die "seeded-leak tests left git's environment in place"
        scripts/sweep.sh --tree || die "tree sweep"
        scripts/sweep.sh --outgoing "$(range)" || die "sweep of these commits"
        ;;
    identity)
        scripts/test-identity.sh || die "identity check self-test"
        scripts/identity.sh "$(range)" || die "commit identity"
        ;;
    lint)
        if [ -n "${CI:-}" ]; then
            brew install shellcheck actionlint || die "installing the lint tools"
        fi
        scripts/lint.sh || die "lint"
        ;;
    deps)
        swift package resolve || die "swift package resolve"
        git diff --exit-code Package.resolved || die "Package.resolved doesn't match Package.swift"
        ;;
    fresh)
        scripts/setup.sh || die "setup.sh"
        [ "$(git config core.hooksPath)" = ".githooks" ] || die "setup.sh didn't install the hooks"
        for hook in pre-commit commit-msg pre-push; do
            [ -x ".githooks/$hook" ] || die "$hook isn't executable after setup"
        done
        echo "fresh clone: hooks installed"
        ;;
    e2e)
        folder="$(scripts/ci-fetch-model.sh)" || die "fetching the model"
        swift build || die "debug build"
        E2E_MODEL="openai_whisper-tiny" E2E_MODEL_FOLDER="$folder" scripts/e2e.sh || die "E2E"
        ;;
    *)
        echo "usage: ci.sh test|leaks|identity|lint|deps|fresh|e2e" >&2
        exit 2
        ;;
esac
