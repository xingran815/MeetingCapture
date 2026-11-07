#!/usr/bin/env bash
# Proves the sweeps and hooks refuse seeded leaks. Runs in a throwaway repo with
# stub lint.sh and check.sh, so it needs no build, shellcheck or actionlint. Seeds are assembled at runtime so this
# file doesn't trip the sweep it tests; every value is invented.
set -uo pipefail

# Finding (M2.1): under a hook in a linked worktree git sets GIT_DIR, so every
# command below hit the real repo: core.bare, the author, branches, even dry-run
# pushes to the real remote. Clear git's repo variables before anything else.
# scripts/test-sweeps-isolation.sh keeps this true.
while IFS= read -r var; do unset "$var"; done < <(git rev-parse --local-env-vars)

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail+1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

GOOD_EMAIL="1+tester@users.noreply.github.com"
REPO="$WORK/repo"
git init -q -b main "$REPO"
cd "$REPO" || exit 2
# Everything below changes config and history, so stop unless this is the temp repo.
if [ "$(git rev-parse --absolute-git-dir)" != "$(pwd -P)/.git" ]; then
    echo "test-sweeps: refusing to run, git isn't using the temporary repo." >&2
    exit 2
fi
git config user.name tester
git config user.email "$GOOD_EMAIL"
mkdir -p scripts .githooks
cp "$SRC/scripts/sweep.sh" "$SRC/scripts/sweep-allow.txt" scripts/
# sweep.sh refuses every push without this list, so the repo needs one. Empty here,
# never the real list.
: > scripts/protected-commits.sha256
cp "$SRC"/.githooks/* .githooks/
# Stubs record each call in $STUB_TRACE. The lint stub fails when STUB_FAIL_LINT is
# set; the check stub fails for --unit when STUB_FAIL_UNIT is set. pre-push must not
# call it at all (D-76), so a pass there proves the hook ignores check.sh.
export STUB_TRACE="$WORK/trace.log"
: > "$STUB_TRACE"
cat > scripts/lint.sh <<'STUB'
#!/usr/bin/env bash
echo "lint $*" >> "$STUB_TRACE"
[ -z "${STUB_FAIL_LINT:-}" ] || { echo "stub lint: seeded failure" >&2; exit 1; }
exit 0
STUB
cat > scripts/check.sh <<'STUB'
#!/usr/bin/env bash
echo "check $*" >> "$STUB_TRACE"
if [ "${1:-}" = "--unit" ] && [ -n "${STUB_FAIL_UNIT:-}" ]; then
    echo "stub check: seeded unit failure" >&2; exit 1
fi
exit 0
STUB
chmod +x scripts/*.sh .githooks/*
git config core.hooksPath .githooks
git add -A
git commit -qm "chore: base" || { echo "base commit refused"; exit 2; }

# Expects the commit to be refused, naming the rule. $1 label, $2 rule, $3 file, $4 content.
blocks() {
    mkdir -p "$(dirname "$3")"
    printf '%s\n' "$4" > "$3"
    git add -f "$3"
    local out
    if out="$(git commit -qm "test: seed" 2>&1)"; then
        bad "$1: commit went through"; git reset -q --hard HEAD~1
    elif printf '%s' "$out" | grep -q "\[$2\]"; then
        ok "$1 blocked by [$2]"
    else
        bad "$1: refused, but rule [$2] not named" "$out"
    fi
    git reset -q --hard HEAD
    git clean -qfdx -e scripts -e .githooks
}

AT="@"; NOTHING=""
KEY="sk-""ant-api03-abcdefghijklmnopqrstuvwxyz012345"
blocks "fake key"             secret-openai-style note.md   "key is $KEY"
blocks "github token"         secret-github-token note.md   "ghp""_abcdefghijklmnopqrstuvwxyz0123"
blocks "aws key"              secret-aws-key      note.md   "AK""IAABCDEFGHIJKLMNOP"
blocks "slack token"          secret-slack-token  note.md   "xox""b-1234567890-abcdefghij"
blocks "private key header"   secret-private-key  note.md   "-----BEGIN RSA PRIVATE"" KEY-----"
blocks "api key assignment"   secret-api-key-value note.md  "LLM_API_""KEY=abcd1234efgh"
blocks "password in url"      secret-url-password note.md   "https://me:hunter2${AT}host.invalid/x"
blocks "token in url"         secret-url-token    note.md   "https://host.invalid/x?token""=abcdefghijklmnop1234"
blocks "hex after secret"     secret-hex-value    note.md   "secret: ${NOTHING}0123456789abcdef0123456789abcdef"
blocks "real-looking email"   identity-email      note.md   "ask jo.bloggs""@realmail.net"
blocks "home path"            identity-user-path  note.md   "see /Us""ers/someone/notes"
blocks "wav file"             sensitive-file      a.wav     "RIFF"
blocks "m4a file"             sensitive-file      a.m4a     "x"
blocks "key file"             sensitive-file      llm_api_keys.json "{}"
blocks "dotenv"               sensitive-file      .env      "x=1"
blocks "transcript txt"       sensitive-file      call.txt  "[00:00:01] hello"
blocks "report html"          sensitive-file      20260101_120000_budget.html "<p>"
blocks "shell process"        code-shell-process  run.swift "let p = \"/bin/""zsh\""
blocks "dangerous flag"       code-dangerous-flag run.swift "args = [\"--danger""ously-skip-permissions\"]"
blocks "hook skip"            code-skip-hooks     run.sh    "git commit --no-""verify"
blocks "logging a key"        code-log-credential run.swift "print(\"key \\(api""Key)\")"
blocks "invisible char"       code-invisible-char note.md   "$(printf 'a\xe2\x80\x8bb')"

# security review M3.2: non-ASCII names were C-quoted by git and bypassed every filename rule.
blocks "security review M3.2: 会议.m4a (non-ASCII)"            sensitive-file "会议.m4a" "x"
blocks "security review M3.2: 会议_transcript.txt"            sensitive-file "会议_transcript.txt" "x"
blocks "security review M3.2: 录音 2.WAV (space, upper case)"  sensitive-file "录音 2.WAV" "x"
blocks "security review M3.2: name with a tab"               sensitive-file "$(printf 'a\tb.m4a')" "x"
blocks "security review M3.2: name with a double quote"      sensitive-file 'say "hi".m4a' "x"
# Exact names only: the folder is no longer a pass.
blocks "security review M3.2: e2e/standup.m4a"      sensitive-file Tests/Fixtures/e2e/standup.m4a "x"
blocks "security review M3.2: e2e/call.wav"         sensitive-file Tests/Fixtures/e2e/call.wav "x"
blocks "security review M3.2: e2e/e2e_mic-48k.caf"  sensitive-file Tests/Fixtures/e2e/e2e_mic-48k.caf "x"
blocks "security review M3.2: e2e/E2E_MIC.caf"      sensitive-file Tests/Fixtures/e2e/E2E_MIC.caf "x"
for f in Rec.MOV a.m4v a.mkv a.mka a.aifc a.m4r a.wma a.au a.snd; do
    blocks "security review M3.2: $f" sensitive-file "rec/$f" "x"
done

# Finding (sweep audio gap: .caf passed): audio in any container is refused, in any case,
# except directly in Tests/Fixtures/e2e/ (invented sentences read by `say`).
for ext in wav m4a mp3 aiff aif caf flac aac ogg opus m4b mp4 webm amr 3gp; do
    blocks "sweep audio gap: .$ext outside the fixtures" sensitive-file "rec/call.$ext" "x"
done
blocks "upper-case MEETING.WAV"      sensitive-file MEETING.WAV "x"
blocks "mixed-case call.Caf"         sensitive-file call.Caf "x"
blocks "sweep audio gap: .caf at top" sensitive-file a.caf "x"
blocks "fixture subfolder e2e/sub/x.caf"          sensitive-file Tests/Fixtures/e2e/sub/x.caf "x"
blocks "other fixture folder x.wav"               sensitive-file Tests/Fixtures/other/x.wav "x"
blocks "file named e2e.caf, not the folder"       sensitive-file Tests/Fixtures/e2e.caf "x"
blocks "xTests/Fixtures/e2e/x.caf (prefix look-alike)" sensitive-file xTests/Fixtures/e2e/x.caf "x"
blocks "nested Tests/Fixtures/e2e/x.caf under a parent" sensitive-file sub/Tests/Fixtures/e2e/x.caf "x"
blocks "upper-case ext in e2e subfolder"          sensitive-file Tests/Fixtures/e2e/sub/X.CAF "x"

# The one exception: a file directly in Tests/Fixtures/e2e/ goes through.
for fx in e2e_mic.caf e2e_system.caf; do
    mkdir -p Tests/Fixtures/e2e; printf 'x\n' > "Tests/Fixtures/e2e/$fx"
    git add -f "Tests/Fixtures/e2e/$fx"
    if out="$(git commit -qm "test: fixture" 2>&1)"; then ok "Tests/Fixtures/e2e/$fx allowed"; git reset -q --hard HEAD~1
    else bad "Tests/Fixtures/e2e/$fx refused" "$out"; git reset -q --hard HEAD; fi
    git clean -qfdx -e scripts -e .githooks
done
git clean -qfdx -e scripts -e .githooks

# Finding: an added line starting "++ " looks like a diff header and was skipped.
blocks "key on a ++ line (header look-alike)" secret-openai-style note.md "++ $KEY"

# A message hook rejects attribution, and a mid-file seed is reported at its line.
printf 'x\n' > ok.md; git add ok.md
TRAILER="Co-Authored""-By: Claude <noreply@anthropic.com>"
if out="$(git commit -qm "$(printf 'feat: x\n\n%s' "$TRAILER")" 2>&1)"; then
    bad "AI attribution: commit went through"; git reset -q --hard HEAD~1
elif printf '%s' "$out" | grep -q '\[ai-attribution\]'; then ok "AI attribution blocked by [ai-attribution]"
else bad "AI attribution: rule not named" "$out"; fi
git reset -q --hard HEAD; git clean -qfd -e scripts -e .githooks

# Author identity.
printf 'x\n' > ok.md; git add ok.md
if out="$(git -c user.email="jo""@realmail.net" commit -qm "feat: x" 2>&1)"; then
    bad "private author email: commit went through"; git reset -q --hard HEAD~1
elif printf '%s' "$out" | grep -q '\[identity-author\]'; then ok "private author email blocked by [identity-author]"
else bad "private author email: rule not named" "$out"; fi
git reset -q --hard HEAD; git clean -qfd -e scripts -e .githooks

# Findings never echo the value.
printf 'key is %s\n' "$KEY" > note.md; git add note.md
out="$(scripts/sweep.sh --staged 2>&1)"
if printf '%s' "$out" | grep -qF "$KEY"; then bad "sweep output contains the matched value"; else ok "sweep output masks the value"; fi
git reset -q --hard HEAD; git clean -qfd -e scripts -e .githooks

# Allowlist passes only the exact value.
FAKE="sk-""FAKEabcdefghijklmnopqrstuvwxyz"
printf 'secret-openai-style\tTests/Fixtures/\t%s\nsecret-openai-style\tscripts/sweep-allow.txt\t%s\n' "$FAKE" "$FAKE" >> scripts/sweep-allow.txt
mkdir -p Tests/Fixtures; printf '%s\n' "$FAKE" > Tests/Fixtures/f.txt
git add -A
if out="$(git commit -qm "test: allowed fake" 2>&1)"; then ok "allowlisted fake value passes"; else bad "allowlisted fake value refused" "$out"; fi
printf '%s\n' "${FAKE}X" > Tests/Fixtures/g.txt; git add -A
if git commit -qm "test: near miss" >/dev/null 2>&1; then bad "near-miss of an allowed value passed"; git reset -q --hard HEAD~1; else ok "near-miss of an allowed value refused"; fi
git reset -q --hard HEAD; git clean -qfd -e scripts -e .githooks

# A clean commit goes through.
printf 'hello\n' > ok.md; git add ok.md
if out="$(git commit -qm "docs: clean" 2>&1)"; then ok "clean commit passes"; else bad "clean commit refused" "$out"; fi

# Hooks fail closed.
mv scripts/sweep.sh "$WORK/sweep.keep"
printf 'y\n' > ok2.md; git add ok2.md
if git commit -qm "docs: y" >/dev/null 2>&1; then bad "commit passed with sweep.sh missing"; git reset -q --hard HEAD~1; else ok "commit refused with sweep.sh missing"; fi
if git push --dry-run "$WORK/none.git" main >/dev/null 2>&1; then bad "push passed with sweep.sh missing"; fi
mv "$WORK/sweep.keep" scripts/sweep.sh
git reset -q HEAD; rm -f ok2.md

mv scripts/lint.sh "$WORK/lint.keep"
printf 'y\n' > ok2.md; git add ok2.md
if out="$(git commit -qm "docs: y" 2>&1)"; then bad "commit passed with lint.sh missing"; git reset -q --hard HEAD~1
elif printf '%s' "$out" | grep -q 'scripts/lint.sh is missing'; then ok "commit refused with lint.sh missing"
else bad "commit with lint.sh missing: refused for another reason" "$out"; fi
mv "$WORK/lint.keep" scripts/lint.sh
git reset -q HEAD; rm -f ok2.md

# Pre-commit runs the sweep first and then lint --staged; a sweep refusal skips lint.
: > "$STUB_TRACE"
printf 'hello again\n' > ok3.md; git add ok3.md
if git commit -qm "docs: lint runs" >/dev/null 2>&1; then ok "commit passes with a passing lint"; else bad "commit refused with a passing lint"; fi
if [ "$(cat "$STUB_TRACE")" = "lint --staged" ]; then ok "pre-commit calls lint.sh --staged"; else bad "pre-commit lint call wrong" "$(cat "$STUB_TRACE")"; fi

printf 'z\n' > ok4.md; git add ok4.md
if out="$(STUB_FAIL_LINT=1 git commit -qm "docs: z" 2>&1)"; then bad "commit passed with a failing lint"; git reset -q --hard HEAD~1
elif printf '%s' "$out" | grep -q 'seeded failure'; then ok "commit refused when lint fails (hook uses lint)"
else bad "failing lint: refused for another reason" "$out"; fi
git reset -q HEAD; rm -f ok4.md

: > "$STUB_TRACE"
printf 'key is %s\n' "$KEY" > note.md; git add note.md
git commit -qm "test: seed" >/dev/null 2>&1
if grep -q '^lint' "$STUB_TRACE"; then bad "lint ran although the sweep refused"; else ok "lint doesn't run after a sweep refusal"; fi
git reset -q --hard HEAD; git clean -qfd -e scripts -e .githooks

# ─── Pushes, against a local bare repo ───────────────────────────────────────
BARE="$WORK/remote.git"
git init -q --bare "$BARE"
git remote add origin "$BARE"
: > "$STUB_TRACE"
if out="$(git push -q origin main 2>&1)"; then ok "clean push passes"; else bad "clean push refused" "$out"; fi
# The hook runs the sweep and nothing else (D-76): check.sh, even a failing one, is not called.
trace="$(cat "$STUB_TRACE")"
if [ -z "$trace" ]; then ok "pre-push doesn't run check.sh"; else bad "pre-push called a stub" "$trace"; fi

git switch -q -c unitfail
printf 'u\n' > u.md; git add u.md; git commit -qm "feat: u"
: > "$STUB_TRACE"
if out="$(STUB_FAIL_UNIT=1 git push --dry-run origin unitfail 2>&1)"; then ok "push passes although check.sh --unit would fail"
else bad "push refused: check.sh must not gate it" "$out"; fi
trace="$(cat "$STUB_TRACE")"
if [ -z "$trace" ]; then ok "a failing check.sh is never invoked by pre-push"; else bad "check.sh was invoked" "$trace"; fi
mv scripts/check.sh "$WORK/check.keep"
if out="$(git push --dry-run origin unitfail 2>&1)"; then ok "push passes with check.sh missing (not needed)"; else bad "push needs check.sh" "$out"; fi
mv "$WORK/check.keep" scripts/check.sh
git switch -q main; git branch -q -D unitfail

mv scripts/sweep.sh "$WORK/sweep.keep"
if out="$(git push --dry-run origin main 2>&1)"; then bad "push passed with sweep.sh missing"
elif printf '%s' "$out" | grep -q 'scripts/sweep.sh is missing'; then ok "push refused with sweep.sh missing"
else bad "sweep.sh missing: refused for another reason" "$out"; fi
mv "$WORK/sweep.keep" scripts/sweep.sh

git switch -q -c feature/coding-interview
printf 'interview\n' > i.md; git add i.md; git commit -qm "feat: private mode"
if out="$(git push --dry-run origin feature/coding-interview 2>&1)"; then
    bad "push of protected branch went through"
elif printf '%s' "$out" | grep -q '\[branch-rule\]'; then ok "protected branch refused by [branch-rule] (dry run)"
else bad "protected branch: rule not named" "$out"; fi

git switch -q -c innocent-name
printf 'more\n' > j.md; git add j.md; git commit -qm "feat: more"
if out="$(git push --dry-run origin innocent-name 2>&1)"; then
    bad "branch descending from the protected one went through"
elif printf '%s' "$out" | grep -q '\[branch-rule\]'; then ok "descendant branch refused by [branch-rule]"
else bad "descendant: rule not named" "$out"; fi

if out="$(git push --dry-run origin innocent-name:refs/heads/feature/coding-interview 2>&1)"; then
    bad "push to the protected name went through"
else ok "push to the protected remote name refused"; fi
git switch -q main

# Outgoing: a commit made with hooks off is still caught at push.
git switch -q -c sneaky
printf 'x\n' > k.md; git add k.md
git -c core.hooksPath=/dev/null -c user.email="jo""@realmail.net" commit -qm "feat: bad author"
: > "$STUB_TRACE"
if out="$(git push --dry-run origin sneaky 2>&1)"; then bad "bad author went through at push"
elif printf '%s' "$out" | grep -q '\[identity-author\]'; then ok "bad author refused at push"
else bad "bad author: rule not named" "$out"; fi
trace="$(cat "$STUB_TRACE")"
if [ -z "$trace" ]; then ok "a sweep refusal blocks the push and check.sh is not called"; else bad "check.sh ran although the sweep refused the push" "$trace"; fi
git reset -q --hard main
printf 'key %s\n' "$KEY" > k.md; git add k.md
git -c core.hooksPath=/dev/null commit -qm "feat: bad diff"
if out="$(git push --dry-run origin sneaky 2>&1)"; then bad "key in an outgoing diff went through"
elif printf '%s' "$out" | grep -q '\[secret-openai-style\]'; then ok "key in an outgoing diff refused"
else bad "outgoing key: rule not named" "$out"; fi

# ─── The protected-commit list (D-62), catching what the branch name can't ───
LIST=scripts/protected-commits.sha256
hash_of() { printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1; }
git switch -q main
git reset -q --hard main; git clean -qfd -e scripts -e .githooks

# A clean push passes with a list that holds other hashes.
git switch -q -c otherlist
hash_of "an-unrelated-id" > "$LIST"; hash_of "another-id" >> "$LIST"
git add "$LIST"; git commit -qm "chore: list of other hashes"
printf 'o\n' > o.md; git add o.md; git commit -qm "feat: o"
if out="$(git push --dry-run origin otherlist 2>&1)"; then ok "clean push passes with a list of other hashes"; else bad "clean push refused with a list of other hashes" "$out"; fi
git switch -q main; git branch -q -D otherlist

# A missing list refuses the push, naming the rule.
git switch -q -c nolist
printf 'n\n' > n.md; git add n.md; git commit -qm "feat: n"
mv "$LIST" "$WORK/list.keep"
if out="$(git push --dry-run origin nolist 2>&1)"; then bad "push passed with the list missing"
elif printf '%s' "$out" | grep -q '\[branch-rule\].*protected-commits.sha256 is missing'; then ok "push refused with the list missing, by [branch-rule]"
else bad "list missing: rule or reason not named" "$out"; fi
mv "$WORK/list.keep" "$LIST"
git switch -q main; git branch -q -D nolist

# A renamed copy with no ref left under the protected name. The list commit comes
# after the seeded one, so it doesn't change the seeded commit's id.
git branch -q -D feature/coding-interview innocent-name 2>/dev/null
git switch -q -c seeded
printf 'private\n' > p.md; git add p.md; git commit -qm "feat: private work"
SEEDED="$(git rev-parse HEAD)"
SEEDED_HASH="$(hash_of "$SEEDED")"
printf '%s\n' "$SEEDED_HASH" > "$LIST"
git add "$LIST"; git commit -qm "chore: list the private commit"
git branch -q -m seeded harmless-name
if [ "$(git rev-parse HEAD~1)" = "$SEEDED" ]; then ok "list commit left the seeded commit's id alone"; else bad "seeded commit id changed"; fi
if git for-each-ref --format='%(refname)' | grep -q 'coding-interview'; then bad "a ref with the protected name still exists"; else ok "no ref carries the protected name"; fi
if out="$(git push --dry-run origin harmless-name 2>&1)"; then bad "renamed copy went through"
elif printf '%s' "$out" | grep -q '\[branch-rule\].*contains a commit from'; then ok "renamed copy refused by [branch-rule] via the list"
else bad "renamed copy: rule or reason not named" "$out"; fi
if printf '%s' "$out" | grep -qF "$SEEDED" || printf '%s' "$out" | grep -qF "$SEEDED_HASH" \
    || printf '%s' "$out" | grep -qF "${SEEDED:0:12}"; then
    bad "refusal output names the commit id or its hash"
else ok "refusal output has neither the commit id nor its hash"; fi
if out="$(git push --dry-run origin harmless-name:other-remote-name 2>&1)"; then bad "renamed copy went through under another remote name"; else ok "renamed copy refused under another remote name too"; fi

# ─── Finding (M3.1): diff-tree printed nothing for a merge, so what a merge adds
# on its own went unswept. Merges are made with hooks off, as a careless one would be.
git switch -q main; git reset -q --hard main; git clean -qfd -e scripts -e .githooks
# $1 name, $2 file the merge adds, $3 its content. Leaves the merge on branch $1.
make_merge() {
    git switch -q -c "$1-a" main
    printf 'a\n' > "$1-a.md"; git add "$1-a.md"; git commit -qm "feat: a side"
    git switch -q -c "$1-b" main
    printf 'b\n' > "$1-b.md"; git add "$1-b.md"; git commit -qm "feat: b side"
    git switch -q "$1-a"
    git merge -q --no-ff --no-commit "$1-b" >/dev/null 2>&1
    if [ -n "${2:-}" ]; then printf '%s\n' "$3" > "$2"; git add -f "$2"; fi
    git -c core.hooksPath=/dev/null commit -qm "merge: $1"
}
make_merge mkey merge-note.md "key is $KEY"
if [ "$(git rev-list --parents -n1 HEAD | wc -w | tr -d ' ')" = "3" ]; then ok "the seeded commit is a merge"; else bad "seeded commit isn't a merge"; fi
if out="$(git push --dry-run origin mkey-a 2>&1)"; then bad "Finding (M3.1): key added only by a merge went through"
elif printf '%s' "$out" | grep -qF '[secret-openai-style]'; then ok "Finding (M3.1): key added only by a merge refused by [secret-openai-style]"
else bad "merge key: rule not named" "$out"; fi
git switch -q main

# security review M3.2: pre-push and the CI tree sweep, with names the old feeders mis-read.
# $1 branch, $2 path. An outgoing commit adding $2, made with hooks off.
make_audio_commit() {
    git switch -q -c "$1" main
    mkdir -p "$(dirname "$2")"; printf 'x\n' > "$2"; git add -f -- "$2"
    git -c core.hooksPath=/dev/null commit -qm "feat: audio"
}
n=0
for f in "rec/call.caf" "会议.m4a" "会议_transcript.txt" "录音 2.WAV"; do
    n=$((n+1)); make_audio_commit "aud$n" "$f"
    if out="$(git push --dry-run origin "aud$n" 2>&1)"; then bad "security review M3.2: push adding $f went through"
    elif printf '%s' "$out" | grep -qF '[sensitive-file]'; then ok "security review M3.2: push adding $f refused by [sensitive-file]"
    else bad "push adding $f: rule not named" "$out"; fi
    if out="$(scripts/sweep.sh --tree 2>&1)"; then bad "security review M3.2: --tree passed with $f"
    elif printf '%s' "$out" | grep -qF '[sensitive-file]'; then ok "security review M3.2: --tree refuses $f"
    else bad "--tree $f: rule not named" "$out"; fi
    git switch -q main
done
git reset -q --hard main; git clean -qfd -e scripts -e .githooks

make_merge mwav merge-call.wav "RIFF"
if out="$(git push --dry-run origin mwav-a 2>&1)"; then bad "Finding (M3.1): sensitive file added only by a merge went through"
elif printf '%s' "$out" | grep -qF '[sensitive-file]'; then ok "Finding (M3.1): sensitive file added only by a merge refused by [sensitive-file]"
else bad "merge wav: rule not named" "$out"; fi
git switch -q main

make_merge mclean "" ""
if out="$(git push --dry-run origin mclean-a 2>&1)"; then ok "a clean merge still passes"; else bad "clean merge refused" "$out"; fi
git switch -q main

# ─── pre-push prints no "working copy" note any more: it runs no tests (D-76) ───
NOTE="isn't what's being pushed"
git reset -q --hard main; git clean -qfd -e scripts -e .githooks
git switch -q -c headpush
printf 'h\n' > h.md; git add h.md; git commit -qm "feat: h"
printf 'dirty\n' > dirty.txt
out="$(git push --dry-run origin headpush 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then bad "push with a dirty tree refused" "$out"
elif printf '%s' "$out" | grep -qF "$NOTE"; then bad "working-copy note still printed" "$out"
else ok "no working-copy note for a dirty tree"; fi
rm -f dirty.txt
git switch -q main
out="$(git push --dry-run origin headpush 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then bad "push of another sha refused" "$out"
elif printf '%s' "$out" | grep -qF "$NOTE"; then bad "working-copy note printed for another sha" "$out"
else ok "no working-copy note when the pushed sha isn't HEAD"; fi
git push -q origin headpush >/dev/null 2>&1
out="$(git push --dry-run origin :headpush 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then ok "a branch deletion still passes"; else bad "branch deletion refused" "$out"; fi

printf '\nsweep tests: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
