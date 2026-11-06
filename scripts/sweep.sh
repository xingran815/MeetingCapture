#!/usr/bin/env bash
# Leak and security sweeps. Regex only, no third-party scanner (docs/specs/01).
#
#   sweep.sh --staged            staged files and the identity about to commit
#   sweep.sh --commit-msg FILE   a commit message
#   sweep.sh --outgoing RANGE    commits, messages and diffs in a rev-list range
#   sweep.sh --pre-push          reads git's pre-push lines on stdin
#   sweep.sh --identity RANGE    authors, committers and messages only
#   sweep.sh --tree              every tracked file as it stands
#
# Findings name the rule, the file and the line, never the matched value, so a
# sweep's own output can't leak what it found. Exit 1 means something was found.
#
# The patterns below are written so they don't match their own source text.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)" || exit 2
ALLOW="$ROOT/scripts/sweep-allow.txt"
PROTECTED_BRANCH="feature/coding-interview"
found=0
TMP="$(mktemp)" || exit 2
trap 'rm -f "$TMP"' EXIT

# Runs a git command into a temp file, then feeds a scanner in this shell. A pipe
# would run the scanner in a subshell and lose found=1, and a failed git command
# must block rather than look like an empty, clean result.
feed() {  # scanner-with-args... -- command...
    local scanner=()
    while [ "$1" != "--" ]; do scanner+=("$1"); shift; done
    shift
    "$@" > "$TMP" || { echo "sweep: command failed: $1 $2" >&2; exit 2; }
    "${scanner[@]}" < "$TMP"
}

report() { printf 'BLOCKED [%s] %s\n' "$1" "$2"; found=1; }

# ─── Line scanner ────────────────────────────────────────────────────────────
# Reads a unified diff on stdin and checks added lines. SWEEP_CODE=1 also runs
# the code-security rules, which only apply to staged changes.
# shellcheck disable=SC2329  # called through feed
scan_diff() {
    SWEEP_ALLOW="$ALLOW" perl -CSD -e '
        use strict; use warnings;
        my @allow;
        if (open(my $fh, "<:encoding(UTF-8)", $ENV{SWEEP_ALLOW})) {
            while (<$fh>) {
                chomp; next if /^\s*(#|$)/;
                my ($rule, $prefix, $text) = split /\t/, $_, 3;
                push @allow, [$rule, $prefix, $text] if defined $text;
            }
        }
        sub allowed {
            my ($rule, $path, $value) = @_;
            for my $a (@allow) {
                return 1 if $a->[0] eq $rule && index($path, $a->[1]) == 0 && $a->[2] eq $value;
            }
            return 0;
        }
        my @secret = (
            ["secret-openai-style",  qr/\bsk-[A-Za-z0-9_-]{16,}/],
            ["secret-github-token",  qr/\bgh[pousr]_[A-Za-z0-9]{20,}/],
            ["secret-aws-key",       qr/\bAKIA[0-9A-Z]{16}\b/],
            ["secret-slack-token",   qr/\bxox[a-z]-[A-Za-z0-9-]{10,}/],
            ["secret-private-key",   qr/-----BEGIN [A-Z ]*PRIVATE KEY-----/],
            ["secret-api-key-value", qr/\b[A-Z0-9_]*API_KEY\s*=\s*["\x27]?[A-Za-z0-9_\-.]{8,}/],
            ["secret-url-password",  qr{\bhttps?://[^/\s:@]+:[^/\s@]+@}],
            ["secret-url-token",     qr/[?&](?:token|api_key|apikey|key|access_token)=[A-Za-z0-9_\-]{16,}/i],
            ["secret-hex-value",     qr/(?:key|token|secret)[^0-9A-Za-z\n]{0,8}[0-9a-fA-F]{32,}/i],
        );
        my @code = (
            ["code-shell-process",   qr{/bin/(?:ba|z|da)?sh\b|\b(?:ba|z)?sh\s+-c\b}],
            ["code-dangerous-flag",  qr/--dangerousl[y]/],
            ["code-skip-hooks",      qr/--no[-]verify/],
            ["code-log-credential",  qr/\b(?:print|fputs|NSLog|os_log|logger\.\w+|debugPrint|dump)\b.*(?:api_?ke[y]|authori[z]ation)/i],
        );
        my $invisible = qr/[\x{00AD}\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{2064}\x{FEFF}]/;
        my $email = qr/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/;
        my $code_on = ($ENV{SWEEP_CODE} // "") eq "1";
        my ($path, $line, $hits, $old_left, $new_left) = ("", 0, 0, 0, 0);
        sub hit { printf "BLOCKED [%s] %s:%d\n", @_; $hits++ }
        while (my $l = <STDIN>) {
            chomp $l;
            # Count hunk lines rather than trusting prefixes: an added line whose
            # text starts with "++ " looks exactly like a file header.
            if ($old_left <= 0 && $new_left <= 0) {
                if ($l =~ m{^\+\+\+ (?:b/)?(.*)$}) { $path = $1; $path =~ s/\t.*//; }
                elsif ($l =~ /^@@ -\d+(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) {
                    $old_left = $1 // 1; $line = $2 - 1; $new_left = $3 // 1;
                }
                next;
            }
            next if $l =~ /^\\/;     # "No newline at end of file"
            if ($l =~ /^-/) { $old_left--; next }
            if ($l !~ /^\+/) { $old_left--; $new_left--; $line++; next }
            $new_left--;
            $line++;
            my $t = substr($l, 1);
            # Vendored upstream licence headers carry public maintainer addresses.
            my $vendored = index($path, "Sources/Speexdsp/") == 0;
            unless ($vendored) {
                while ($t =~ /($email)/g) {
                    my $v = $1;
                    next if $v =~ /\@(?:[A-Za-z0-9-]+\.)*example\.(?:com|org|cn)$/i;
                    next if $v =~ /noreply/i;
                    next if $v =~ /^git\@/;
                    next if allowed("identity-email", $path, $v);
                    hit("identity-email", $path, $line);
                }
                while ($t =~ m{(/Users/[A-Za-z0-9._-]+/)}g) {
                    my $v = $1;
                    next if $v eq "/Users/Shared/" || allowed("identity-user-path", $path, $v);
                    hit("identity-user-path", $path, $line);
                }
            }
            for my $r (@secret) {
                while ($t =~ /($r->[1])/g) {
                    hit($r->[0], $path, $line) unless allowed($r->[0], $path, $1);
                }
            }
            hit("code-invisible-char", $path, $line) if $t =~ $invisible;
            next unless $code_on;
            next if $path =~ /\.md$/;   # rules and specs have to be able to name these
            for my $r (@code) {
                hit($r->[0], $path, $line) if $t =~ $r->[1] && !allowed($r->[0], $path, $&);
            }
        }
        exit($hits ? 1 : 0);
    ' || found=1
}

# Reads a commit message on stdin. $1 labels the findings.
scan_message() {
    SWEEP_LABEL="$1" perl -CSD -e '
        use strict; use warnings;
        my $email = qr/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}/;
        my $hits = 0;
        sub hit { printf "BLOCKED [%s] %s\n", $_[0], $ENV{SWEEP_LABEL}; $hits++ }
        while (my $l = <STDIN>) {
            next if $ENV{SWEEP_STRIP_COMMENTS} && $l =~ /^#/;     # git strips these
            hit("ai-attribution") if $l =~ /^\s*co-authored-by:.*(?:claude|anthropic|codex|gpt)/i;
            while ($l =~ /($email)/g) {
                my $v = $1;
                next if $v =~ /noreply/i || $v =~ /\@(?:[A-Za-z0-9-]+\.)*example\.(?:com|org|cn)$/i;
                hit("identity-email");
            }
            hit("identity-user-path") if $l =~ m{/Users/[A-Za-z0-9._-]+/} && $l !~ m{/Users/Shared/};
            hit("secret-in-message") if $l =~ /\bsk-[A-Za-z0-9_-]{16,}|\bgh[pousr]_[A-Za-z0-9]{20,}|\bAKIA[0-9A-Z]{16}\b|\bxox[a-z]-[A-Za-z0-9-]{10,}|-----BEGIN [A-Z ]*PRIVATE KEY-----/;
        }
        exit($hits ? 1 : 0);
    ' || found=1
}

# Reads file paths on stdin.
# shellcheck disable=SC2329  # called through feed
scan_filenames() {
    local path base
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        base="${path##*/}"
        case "$base" in
            llm_api_keys.json|auth.json|.env|.env.*)
                report sensitive-file "$path" ;;
            *.wav|*.m4a|*.mp3|*.aiff)
                report sensitive-file "$path" ;;
            meeting_*.md|meeting_*.html|meeting_*.txt|*_transcript.*|*_summary.md)
                report sensitive-file "$path" ;;
        esac
        # Reports are named <timestamp>_<topic>.html.
        case "$base" in
            [0-9][0-9][0-9][0-9]*_*.html) report sensitive-file "$path" ;;
        esac
        # Transcripts are .txt. Only the sweep's own list and fixtures may be.
        case "$path" in
            scripts/sweep-allow.txt|Tests/Fixtures/*|README*.txt) ;;
            *.txt) report sensitive-file "$path" ;;
        esac
    done
}

check_email() {  # label, email
    case "$2" in
        *@users.noreply.github.com) ;;
        *) report identity-author "$1" ;;
    esac
}

sweep_staged() {
    check_email "author about to commit" "$(git var GIT_AUTHOR_IDENT | sed -E 's/.*<(.*)>.*/\1/')"
    check_email "committer about to commit" "$(git var GIT_COMMITTER_IDENT | sed -E 's/.*<(.*)>.*/\1/')"
    feed scan_filenames -- git diff --cached --name-only --diff-filter=ACMRT
    SWEEP_CODE=1 feed scan_diff -- git diff --cached -U0 --no-color --no-ext-diff --diff-filter=ACMRT
}

identity_of() {  # commit
    local short="${1:0:9}"
    check_email "commit $short author" "$(git log -1 --format=%ae "$1")"
    check_email "commit $short committer" "$(git log -1 --format=%ce "$1")"
    feed scan_message "commit $short message" -- git log -1 --format=%B "$1"
}

# Who made each commit and what its message says, without reading the diffs.
sweep_identity() {  # rev-list arguments
    local sha
    local shas
    shas="$(git rev-list "$@")" || { echo "sweep: bad range" >&2; exit 2; }
    for sha in $shas; do identity_of "$sha"; done
}

sweep_outgoing() {  # rev-list arguments
    local sha
    local shas
    shas="$(git rev-list "$@")" || { echo "sweep: bad range" >&2; exit 2; }
    for sha in $shas; do
        local short="${sha:0:9}"
        identity_of "$sha"
        feed scan_filenames -- git diff-tree --root --no-commit-id -r --name-only --diff-filter=ACMRT "$sha"
        feed scan_diff -- git diff-tree --root --no-commit-id -p -U0 --no-color --no-ext-diff --diff-filter=ACMRT "$sha"
    done
}

# Prints every tracked text file as an all-added diff, for scan_diff.
# shellcheck disable=SC2329,SC2016  # called through feed; the single quotes hold perl
tree_as_diff() {
    git grep -Ilz '' | xargs -0 perl -e '
        for my $f (@ARGV) {
            open(my $h, "<", $f) or die "sweep: cannot read a tracked file\n";
            my @lines = <$h>;
            next unless @lines;
            printf "+++ b/%s\n@@ -0,0 +1,%d @@\n", $f, scalar @lines;
            for (@lines) { s/\n?$/\n/; print "+$_" }
        }'
}

sweep_tree() {
    feed scan_filenames -- git ls-files
    feed scan_diff -- tree_as_diff
}

# Refuses the protected branch by name, and any commit that exists only on it,
# which also catches a branch cut from the middle of it.
branch_rule() {  # local_ref local_sha remote_ref
    case "$1 $3" in
        *"$PROTECTED_BRANCH"*) report branch-rule "push of $PROTECTED_BRANCH" ; return ;;
    esac
    git rev-parse -q --verify "refs/heads/$PROTECTED_BRANCH" >/dev/null || return 0
    local base=()
    git rev-parse -q --verify refs/heads/main >/dev/null && base=(--not refs/heads/main)
    local only
    only="$(git rev-list "refs/heads/$PROTECTED_BRANCH" ${base[@]+"${base[@]}"} | sort)"
    [ -n "$only" ] || return 0
    if [ -n "$(git rev-list "$2" | sort | comm -12 - <(printf '%s\n' "$only") | head -1)" ]; then
        report branch-rule "$1 contains commits from $PROTECTED_BRANCH"
    fi
}

sweep_pre_push() {
    local zero=0000000000000000000000000000000000000000
    local local_ref local_sha remote_ref _
    while read -r local_ref local_sha remote_ref _; do
        [ -n "${local_ref:-}" ] || continue
        [ "$local_sha" = "$zero" ] && continue   # a deletion sends no commits
        branch_rule "$local_ref" "$local_sha" "$remote_ref"
        sweep_outgoing "$local_sha" --not --remotes
    done
}

cd "$ROOT" || exit 2
case "${1:-}" in
    --staged)     sweep_staged ;;
    --commit-msg) [ -r "${2:-}" ] || { echo "sweep: unreadable message file" >&2; exit 2; }
                  SWEEP_STRIP_COMMENTS=1 scan_message "commit message" < "$2" ;;
    --outgoing)   shift; sweep_outgoing "$@" ;;
    --pre-push)   sweep_pre_push ;;
    --identity)   shift; sweep_identity "$@" ;;
    --tree)       sweep_tree ;;
    *) echo "usage: sweep.sh --staged | --commit-msg FILE | --outgoing RANGE | --identity RANGE | --pre-push | --tree" >&2; exit 2 ;;
esac

if [ "$found" -ne 0 ]; then
    echo "sweep: blocked. Fix the finding above; don't skip the hook." >&2
    exit 1
fi
exit 0
