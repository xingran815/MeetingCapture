#!/usr/bin/env bash
# The one lint, used by the pre-commit hook and CI. Every tool is required, so a
# local pass means the same as a CI pass.
#
# lint.sh           the whole tree, as CI runs it
# lint.sh --staged  only what's staged, judged on the staged text, for pre-commit
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2
failed=0

MODE="${1:-}"
case "$MODE" in
    ""|--staged) ;;
    *) echo "usage: lint.sh [--staged]" >&2; exit 2 ;;
esac

for tool in shellcheck actionlint; do
    if ! command -v "$tool" > /dev/null; then
        echo "lint: FAILED, $tool isn't installed. Run: brew install shellcheck actionlint" >&2
        failed=1
    fi
done

# Sources/Speexdsp is vendored, so it isn't ours to format.
SWIFT_ROOTS=(Package.swift Sources/MeetingCaptureCore Sources/MeetingCaptureCLI Sources/MeetingCaptureDesktop Tests)

format_failed() {
    echo "lint: FAILED, swift format. Fix with: swift format -i -r ${SWIFT_ROOTS[*]}" >&2
    failed=1
}

if [ "$MODE" = "--staged" ]; then
    # A partly staged file must be judged on what's being committed, so the tools
    # read a copy of the index, not the working copy. Git points GIT_INDEX_FILE at
    # the right index for `git commit -a` and `git commit <path>` too.
    work="$(mktemp -d)" || exit 2
    trap 'rm -rf "$work"' EXIT
    git checkout-index --all --prefix="$work/" || { echo "lint: FAILED, couldn't read the index." >&2; exit 1; }

    swift_files=(); shell_files=(); all_swift=0; workflows=0
    listing="$work/.staged-list"
    git diff --cached --name-only -z --diff-filter=ACMRT > "$listing" || { echo "lint: FAILED, couldn't list staged files." >&2; exit 1; }
    while IFS= read -r -d '' path; do
        case "$path" in
            Package.swift|Sources/MeetingCaptureCore/*.swift|Sources/MeetingCaptureCLI/*.swift|Sources/MeetingCaptureDesktop/*.swift|Tests/*.swift)
                swift_files+=("$path") ;;
            .swift-format) all_swift=1 ;;
            scripts/*.sh|.githooks/*) shell_files+=("$path") ;;
            .github/workflows/*) workflows=1 ;;
        esac
        [ "$path" = "scripts/check-workflows.sh" ] && workflows=1
    done < "$listing"

    if [ "$all_swift" -eq 1 ]; then
        (cd "$work" && swift format lint --strict --recursive "${SWIFT_ROOTS[@]}") || format_failed
    elif [ "${#swift_files[@]}" -gt 0 ]; then
        (cd "$work" && swift format lint --strict "${swift_files[@]}") || format_failed
    fi

    if [ "${#shell_files[@]}" -gt 0 ] && command -v shellcheck > /dev/null; then
        (cd "$work" && shellcheck "${shell_files[@]}") || { echo "lint: FAILED, shellcheck." >&2; failed=1; }
    fi

    if [ "$workflows" -eq 1 ]; then
        if command -v actionlint > /dev/null; then
            (cd "$work" && actionlint .github/workflows/*.yml) || { echo "lint: FAILED, actionlint." >&2; failed=1; }
        fi
        # The staged script judges the staged workflows.
        "$work/scripts/check-workflows.sh" --self-test || failed=1
        "$work/scripts/check-workflows.sh" || failed=1
    fi

    [ "$failed" -eq 0 ] && echo "lint: ok (staged)"
    exit "$failed"
fi

swift format lint --strict --recursive "${SWIFT_ROOTS[@]}" || format_failed

if command -v shellcheck > /dev/null; then
    shellcheck scripts/*.sh .githooks/* || { echo "lint: FAILED, shellcheck." >&2; failed=1; }
fi

if command -v actionlint > /dev/null; then
    actionlint || { echo "lint: FAILED, actionlint." >&2; failed=1; }
fi

scripts/check-workflows.sh --self-test || failed=1
scripts/check-workflows.sh || failed=1

[ "$failed" -eq 0 ] && echo "lint: ok"
exit "$failed"
