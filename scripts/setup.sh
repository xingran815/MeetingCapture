#!/usr/bin/env bash
# Points git at the repo's hooks. Idempotent; install.sh calls it.
set -euo pipefail
root="$(git rev-parse --show-toplevel)"
cd "$root"
chmod +x .githooks/* scripts/*.sh
git config core.hooksPath .githooks
echo "Hooks installed: core.hooksPath = .githooks"
for tool in shellcheck actionlint; do
    command -v "$tool" > /dev/null || echo "Commits need $tool too. Run: brew install shellcheck actionlint"
done
