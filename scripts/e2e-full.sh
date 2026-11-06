#!/usr/bin/env bash
# The long end to end run: many cases through the real binary and a cached Whisper
# model, each reported by name. Local only (D-49): CI runs just scripts/e2e.sh.
# Every case runs, even after a failure, and the exit code is non-zero if any failed.
#
#   scripts/e2e-full.sh              all cases
#   scripts/e2e-full.sh noise mixed  only cases whose name contains one of these words
#   scripts/e2e-full.sh --list       names only
#
# Skips with a message when no model is cached. E2E_MODEL and E2E_MODEL_FOLDER override.
# Fixtures are invented: `say` voices and generated noise, 5 to 60 seconds long.
#
# Isolation: every run of the binary gets CFFIXED_USER_HOME pointing into dev/tmp, so
# its config, API keys, usage ledger and the output folder that retention and
# --audio-cleanup act on are all inside dev/tmp. The script proves this before any case
# and stops if it can't. It never records: the cases that reach the capture code are
# the refusals, which exit before it, and they carry --duration 2 and a time limit anyway.
# The case_* functions are called by name from the runner, which shellcheck can't follow.
# shellcheck disable=SC2329
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

CASE_NAMES=(
    silence-around-speech
    mic-only
    system-only
    both-silent
    overlapping-talk
    two-system-voices
    noise-before-speech-unpinned
    noise-only-mic
    multipart-wav
    multipart-m4a-and-wav
    crashed-wav-audio-kept
    crashed-wav-transcribe-only
    transcribe-only-wav
    transcribe-only-m4a
    non-english
    output-refused
    script-flags-need-env
    existing-m4a-kept
)

if [ "${1:-}" = "--list" ]; then
    printf '%s\n' "${CASE_NAMES[@]}"
    exit 0
fi

# A case that is known to fail gets its reason here. It is still run and reported as
# KNOWN FAIL, and it counts as a failure if it starts to pass, so the mark can't go stale.
known_failure() {
    case "$1" in
        *) ;;
    esac
}

MODEL="${E2E_MODEL:-openai_whisper-small}"
FOLDER="${E2E_MODEL_FOLDER:-$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml/$MODEL}"
SPEAKER_MODELS="$HOME/Documents/huggingface/models/argmaxinc/speakerkit-coreml"
if [ ! -d "$FOLDER" ]; then
    echo "e2e-full: SKIPPED, no cached model $MODEL. Nothing was downloaded."
    exit 0
fi
if [ ! -d "$SPEAKER_MODELS" ]; then
    echo "e2e-full: SKIPPED, no cached speaker detection model. Nothing was downloaded."
    exit 0
fi
for tool in say afconvert afinfo perl python3 plutil shasum; do
    command -v "$tool" > /dev/null || { echo "e2e-full: FAILED, $tool isn't installed." >&2; exit 2; }
done

BIN="$ROOT/.build/debug/MeetingCaptureCLI"
[ -x "$BIN" ] || { echo "e2e-full: FAILED, build first: swift build" >&2; exit 2; }
WORK="$ROOT/dev/tmp/e2e-full"
FIX="$WORK/fixtures"
CASES="$WORK/cases"
FAKE_HOME="$WORK/home"
mkdir -p "$FIX"
rm -rf "${CASES:?}" "${FAKE_HOME:?}"
mkdir -p "$CASES" "$FAKE_HOME/Documents"
# Speaker models come from the cache the short E2E uses, never from the network.
ln -s "$HOME/Documents/huggingface" "$FAKE_HOME/Documents/huggingface"

export CFFIXED_USER_HOME="$FAKE_HOME"
# Needed by the script-only flags that build fixtures and finish a recording by path.
export MEETINGCAPTURE_E2E=1

# Proof of isolation. --audio-cleanup creates and reads the configured output folder,
# and answers "leave them" on empty input, so it can't delete anything.
isolation_check() {
    local out
    out="$(perl -e 'alarm shift; exec @ARGV' 60 "$BIN" --audio-cleanup < /dev/null 2>&1)" || {
        echo "e2e-full: FAILED, the isolation check didn't run: $out" >&2
        exit 2
    }
    case "$out" in
        *"in $FAKE_HOME/Documents/MeetingCapture"*) ;;
        *)
            echo "e2e-full: STOPPED. The binary didn't use the isolated home, so no case was run." >&2
            exit 2
            ;;
    esac
    [ -d "$FAKE_HOME/Documents/MeetingCapture" ] || { echo "e2e-full: STOPPED, the isolated output folder wasn't made." >&2; exit 2; }
}
isolation_check

# ---------- fixtures ----------
audio() { python3 -I "$ROOT/scripts/e2e-audio.py" "$@"; }

SAY_VOICES="$(say -v '?')"
have_voice() { printf '%s\n' "$SAY_VOICES" | grep -q "^$1 "; }

speak() {  # name, text, [voice]: a mono 48 kHz WAV in $FIX, made once
    local name="$1" text="$2" voice="${3:-}"
    [ -f "$FIX/$name.wav" ] && return 0
    if [ -n "$voice" ]; then
        say -v "$voice" -o "$FIX/$name.aiff" "$text" || exit 2
    else
        say -o "$FIX/$name.aiff" "$text" || exit 2
    fi
    afconvert -f WAVE -d LEI16@48000 -c 1 "$FIX/$name.aiff" "$FIX/$name.wav" || exit 2
}
silence() {  # seconds -> path in $FIX
    local f="$FIX/silence_$1.wav"
    [ -f "$f" ] || audio silence "$f" "$1"
    echo "$f"
}
noise() {  # seconds, amplitude -> path in $FIX
    local f="$FIX/noise_$1_$2.wav"
    [ -f "$f" ] || audio noise "$f" "$1" "$2" 7
    echo "$f"
}

FOX="The quick brown fox jumps over the lazy dog."
FRIDAY="We will ship the report on Friday."
BUDGET="The budget was approved by the board last Tuesday."
THANKS="Thank you everyone for joining the call today."
LONG_MIC="The quick brown fox jumps over the lazy dog. Then the dog walks slowly home through the quiet garden and sleeps."
speak fox "$FOX"
speak friday "$FRIDAY"
speak budget "$BUDGET"
speak thanks "$THANKS"
speak long_mic "$LONG_MIC"

# ---------- running the binary ----------
run_bin() {  # log, args...: merged output in the log, a time limit, no keyboard
    local log="$1"
    shift
    perl -e 'alarm shift; exec @ARGV' 240 "$BIN" "$@" > "$log" 2>&1 < /dev/null
}

# Builds a two-track WAV through the real writer. The system track always starts 6 s in.
build() {  # mic.wav system.wav out.wav
    run_bin "$3.build.log" --two-track-mic "$1" --two-track-system "$2" --two-track-out "$3" \
        || { echo "    FAIL: couldn't build the fixture $3"; cat "$3.build.log"; exit 1; }
}

# Runs the real finish step on a WAV and leaves the output next to it as <base>.run.log.
finish() {  # base, extra args...
    local base="$1"
    shift
    run_bin "$base.run.log" --finish-recording "$base.wav" --model "$MODEL" --model-folder "$FOLDER" "$@" \
        || { echo "    FAIL: the binary exited with an error"; sed 's/^/      | /' "$base.run.log" | tail -15; exit 1; }
}

transcribe_only() {  # log, path, extra args...
    local log="$1" path="$2"
    shift 2
    run_bin "$log" --transcribe-only "$path" --model "$MODEL" --model-folder "$FOLDER" "$@" \
        || { echo "    FAIL: the binary exited with an error"; sed 's/^/      | /' "$log" | tail -15; exit 1; }
}

# ---------- checks; each one ends the case with exit 1 when it fails ----------
fail() { echo "    FAIL: $*"; exit 1; }

show() { sed 's/^/      | /' "$1"; }

# Some line of this speaker matches the pattern, inside a window of seconds.
expect_line() {  # txt, label, pattern, from, to
    perl -CSDA -Mutf8 -e '
        my ($label, $re, $from, $to, $file) = @ARGV;
        open(my $fh, "<:utf8", $file) or exit 3;
        while (<$fh>) {
            next unless /^\[(\d+):(\d+):(\d+)\] \Q$label\E: (.*)$/;
            my ($h, $m, $s, $text) = ($1, $2, $3, $4);
            next unless $text =~ /$re/i;
            my $at = $h * 3600 + $m * 60 + $s;
            exit 0 if $at >= $from && $at <= $to;
        }
        exit 1;
    ' "$2" "$3" "$4" "$5" "$1" || { echo "    FAIL: no \"$2\" line like /$3/ between $4 and $5 s. The transcript:"; show "$1"; exit 1; }
}

# No line is labelled with this speaker (a regex, so "Speaker \d+" works).
expect_no_label() {  # txt, label regex
    if grep -Eq "^\[[0-9:]+\] $2( \(part [0-9]+\))?: " "$1"; then
        echo "    FAIL: found a line labelled /$2/, expected none. The transcript:"
        show "$1"
        exit 1
    fi
}

# No line of this speaker matches the pattern.
expect_no_words() {  # txt, label, pattern
    if grep -Ei "^\[[0-9:]+\] $2: .*($3)" "$1" > /dev/null; then
        echo "    FAIL: $2 has a line like /$3/, which belongs to the other track. The transcript:"
        show "$1"
        exit 1
    fi
}

expect_lines() {  # txt, count: nothing invented beyond the real speech
    local n
    n="$(grep -Ec '^\[[0-9:]+\] ' "$1")"
    [ "$n" -eq "$2" ] || { echo "    FAIL: $n transcript lines, expected $2:"; show "$1"; exit 1; }
}

expect_empty() {  # txt
    if grep -q '[^[:space:]]' "$1"; then
        echo "    FAIL: the transcript should be empty:"
        show "$1"
        exit 1
    fi
}

seconds() { afinfo "$1" | awk '/estimated duration/ {print $3}'; }

# Perl for the sums, because bash has no floats.
plus() { perl -e 'printf "%.1f", $ARGV[0] + $ARGV[1]' "$1" "$2"; }

expect_close() {  # what, a, b, tolerance
    perl -e 'exit(abs($ARGV[0] - $ARGV[1]) <= $ARGV[2] ? 0 : 1)' "$2" "$3" "$4" \
        || fail "$1: $2 s against $3 s, more than $4 s apart"
}

# The WAV went, a good M4A of the same length took its place.
expect_archived() {  # base, original seconds
    [ ! -e "$1.wav" ] || fail "$1.wav is still there"
    [ -s "$1.m4a" ] || fail "no M4A for $1"
    expect_close "the M4A's length" "$(seconds "$1.m4a")" "$2" 0.6
}

expect_transcribed_in_sidecar() {  # base, yes|no
    local sidecar="$1.mcmeta.json"
    plutil -extract state raw -o - "$sidecar" 2> /dev/null | grep -qx processed || fail "$sidecar isn't processed"
    if plutil -extract transcribedAt raw -o - "$sidecar" > /dev/null 2>&1; then
        [ "$2" = yes ] || fail "$sidecar says the recording was transcribed, but it had no speech"
    else
        [ "$2" = no ] || fail "$sidecar doesn't say the recording was transcribed"
    fi
}

# Every audio file the sidecar lists exists, and at least one is listed.
expect_audio_kept() {  # base
    local list file
    list="$(plutil -extract audioFiles json -o - "$1.mcmeta.json" | tr -d '[]"' | tr ',' '\n')"
    [ -n "$list" ] || fail "the sidecar lists no audio"
    while IFS= read -r file; do
        [ -s "$(dirname "$1")/$file" ] || fail "the sidecar lists $file, but it's gone"
    done <<< "$list"
}

expect_log() {  # log, fixed text
    grep -qF "$2" "$1" || { echo "    FAIL: the output never says \"$2\":"; show "$1" | tail -20; exit 1; }
}

# ---------- cases; each gets its own empty folder ----------

case_silence_around_speech() {
    local d="$1"
    # The system track starts 6 s later still, so friday lands at 3 + 6 = 9 s.
    audio cat "$d/mic.wav" "$(silence 5)" "$FIX/fox.wav" "$(silence 5)"
    audio cat "$d/sys.wav" "$(silence 3)" "$FIX/friday.wav" "$(silence 4)"
    build "$d/mic.wav" "$d/sys.wav" "$d/call.wav"
    local before
    before="$(seconds "$d/call.wav")"
    finish "$d/call" --language en
    expect_line "$d/call.txt" You fox 4 8
    expect_line "$d/call.txt" "Speaker 1" friday 8 13
    expect_lines "$d/call.txt" 2
    expect_archived "$d/call" "$before"
    expect_transcribed_in_sidecar "$d/call" yes
}

case_mic_only() {
    local d="$1"
    build "$FIX/fox.wav" "$(silence 8)" "$d/call.wav"
    local before
    before="$(seconds "$d/call.wav")"
    finish "$d/call" --language en
    expect_line "$d/call.txt" You fox 0 5
    expect_no_label "$d/call.txt" "Speaker [0-9]+"
    expect_no_label "$d/call.txt" "Others"
    expect_lines "$d/call.txt" 1
    expect_archived "$d/call" "$before"
}

case_system_only() {
    local d="$1"
    build "$(silence 10)" "$FIX/friday.wav" "$d/call.wav"
    local before
    before="$(seconds "$d/call.wav")"
    finish "$d/call" --language en
    expect_line "$d/call.txt" "Speaker 1" friday 5 12
    expect_no_label "$d/call.txt" You
    expect_lines "$d/call.txt" 1
    expect_archived "$d/call" "$before"
}

case_both_silent() {
    local d="$1"
    build "$(silence 10)" "$(silence 4)" "$d/call.wav"
    local before
    before="$(seconds "$d/call.wav")"
    finish "$d/call" --language en
    expect_empty "$d/call.txt"
    # Silent audio is still a recording: it stays, and it isn't marked as transcribed,
    # so retention can't delete it later on the strength of an empty transcript.
    expect_transcribed_in_sidecar "$d/call" no
    expect_audio_kept "$d/call"
    if [ -e "$d/call.m4a" ]; then expect_archived "$d/call" "$before"; fi
}

case_overlapping_talk() {
    local d="$1"
    # The mic is still talking when the system track starts at 6 s.
    build "$FIX/long_mic.wav" "$FIX/friday.wav" "$d/call.wav"
    finish "$d/call" --language en
    expect_line "$d/call.txt" You fox 0 5
    expect_line "$d/call.txt" You "garden|sleeps|slowly" 0 14
    expect_line "$d/call.txt" "Speaker 1" friday 5 10
    expect_no_words "$d/call.txt" You "friday|ship the report"
    expect_no_words "$d/call.txt" "Speaker 1" "fox|garden"
}

case_two_system_voices() {
    local d="$1"
    if ! have_voice Daniel || ! have_voice Samantha; then
        echo "SKIPPED: the Daniel and Samantha voices aren't installed"
        exit 77
    fi
    # About 12 s each. With one 3 s sentence each, speaker detection merged the two voices
    # into Speaker 1, which looks like the limit of the model on very short turns.
    speak plan_daniel "Good morning. I wanted to walk you through the plan for the next quarter. First we will finish the migration, then we will train the new team, and after that we will review the budget together with finance." Daniel
    speak concerns_samantha "Thanks for that overview. I have a few concerns about the schedule. The migration usually takes longer than expected, so I would like to add two extra weeks, and I would also like to see the risks written down." Samantha
    audio cat "$d/sys.wav" "$FIX/plan_daniel.wav" "$(silence 2)" "$FIX/concerns_samantha.wav"
    build "$(silence 5)" "$d/sys.wav" "$d/call.wav"
    finish "$d/call" --language en
    expect_no_label "$d/call.txt" You
    local first second
    first="$(sed -nE 's/^\[[0-9:]+\] (Speaker [0-9]+): .*(migration|quarter|budget).*/\1/p' "$d/call.txt" | head -1)"
    second="$(sed -nE 's/^\[[0-9:]+\] (Speaker [0-9]+): .*(concerns|schedule|risks).*/\1/p' "$d/call.txt" | head -1)"
    if [ -z "$first" ] || [ -z "$second" ]; then
        echo "    FAIL: a speaker's words are missing:"
        show "$d/call.txt"
        exit 1
    fi
    [ "$first" != "$second" ] || { echo "    FAIL: both voices got the label $first:"; show "$d/call.txt"; exit 1; }
}

case_noise_before_speech_unpinned() {
    local d="$1"
    # Finding from the M3 deep review: 35 s of quiet steady noise before the speech
    # made language detection pick Welsh and lose the sentence. No --language here.
    audio cat "$d/mic.wav" "$(noise 35 0.003)" "$FIX/fox.wav"
    build "$d/mic.wav" "$FIX/friday.wav" "$d/call.wav"
    finish "$d/call"
    expect_line "$d/call.txt" You fox 33 42
    expect_line "$d/call.txt" "Speaker 1" friday 5 12
    expect_lines "$d/call.txt" 2
    if grep '^   language:' "$d/call.run.log" | grep -qv 'language: en$'; then
        echo "    FAIL: a track was detected as another language than English:"
        grep '^   language:' "$d/call.run.log"
        exit 1
    fi
}

case_noise_only_mic() {
    local d="$1"
    build "$(noise 35 0.003)" "$FIX/friday.wav" "$d/call.wav"
    local before
    before="$(seconds "$d/call.wav")"
    finish "$d/call"
    expect_log "$d/call.run.log" "held only quiet, steady noise"
    expect_no_label "$d/call.txt" You
    expect_line "$d/call.txt" "Speaker 1" friday 5 12
    expect_lines "$d/call.txt" 1
    # The noise is audio the user may want to listen to, so it stays in the M4A.
    expect_archived "$d/call" "$before"
}

# Two parts of one recording: the second part is Thank-you on the mic, budget on the system track.
make_part_two() {  # path
    build "$FIX/thanks.wav" "$FIX/budget.wav" "$1"
}

expect_both_parts() {  # txt, part one seconds, log
    local txt="$1" offset="$2" log="$3"
    expect_line "$txt" You fox 0 5
    expect_line "$txt" "Speaker 1" friday 5 12
    expect_line "$txt" You "thank|joining|everyone" "$(plus "$offset" -1)" "$(plus "$offset" 5)"
    expect_line "$txt" "Speaker 1 (part 2)" "budget|approved|board" "$(plus "$offset" 5)" "$(plus "$offset" 12)"
    expect_log "$log" "This recording has 2 parts"
}

case_multipart_wav() {
    local d="$1"
    build "$FIX/fox.wav" "$FIX/friday.wav" "$d/call.wav"
    make_part_two "$d/call_part2.wav"
    local offset
    offset="$(seconds "$d/call.wav")"
    local sums
    sums="$(cd "$d" && shasum call.wav call_part2.wav)"
    transcribe_only "$d/run.log" "$d/call.wav" --language en
    expect_both_parts "$d/call.txt" "$offset" "$d/run.log"
    # A transcript-only run doesn't archive, and leaves healthy WAVs byte for byte as they were.
    [ -s "$d/call.wav" ] && [ -s "$d/call_part2.wav" ] || fail "transcribe-only removed a WAV"
    [ "$(cd "$d" && shasum call.wav call_part2.wav)" = "$sums" ] || fail "a healthy WAV changed"
    [ ! -e "$d/call.m4a" ] || fail "transcribe-only made an M4A"
}

case_multipart_m4a_and_wav() {
    local d="$1"
    build "$FIX/fox.wav" "$FIX/friday.wav" "$d/first.wav"
    make_part_two "$d/call_part2.wav"
    afconvert -f m4af -d aac -b 128000 "$d/first.wav" "$d/call.m4a" || fail "couldn't make the M4A part"
    local offset
    offset="$(seconds "$d/call.m4a")"
    rm -f "${d:?}/first.wav"
    transcribe_only "$d/run.log" "$d/call.m4a" --language en
    expect_both_parts "$d/call.txt" "$offset" "$d/run.log"
}

case_crashed_wav_audio_kept() {
    local d="$1"
    build "$FIX/fox.wav" "$FIX/friday.wav" "$d/call.wav"
    local before
    before="$(seconds "$d/call.wav")"
    audio crash "$d/call.wav"
    perl -e 'exit($ARGV[0] == 0 ? 0 : 1)' "$(seconds "$d/call.wav")" || fail "the fixture should declare no audio, and says $(seconds "$d/call.wav") s"
    finish "$d/call" --language en
    # Nothing lost: the M4A has the whole recording although the header said none.
    # (Its transcript isn't checked here: --finish-recording doesn't repair the header
    # first, as the interactive recovery does. crashed-wav-transcribe-only covers that.)
    expect_archived "$d/call" "$before"
    expect_audio_kept "$d/call"
}

case_crashed_wav_transcribe_only() {
    local d="$1"
    build "$FIX/fox.wav" "$FIX/friday.wav" "$d/call.wav"
    local before
    before="$(seconds "$d/call.wav")"
    audio crash "$d/call.wav"
    transcribe_only "$d/run.log" "$d/call.wav" --language en
    expect_line "$d/call.txt" You fox 0 5
    expect_line "$d/call.txt" "Speaker 1" friday 5 12
    # The header was repaired, so the WAV now says how long it is, and nothing else was made.
    perl -e 'exit(abs($ARGV[0] - $ARGV[1]) < 0.5 ? 0 : 1)' "$(seconds "$d/call.wav")" "$before" \
        || fail "the repaired WAV says $(seconds "$d/call.wav") s, not $before s"
    [ ! -e "$d/call.m4a" ] || fail "transcribe-only made an M4A"
}

case_transcribe_only_wav() {
    local d="$1"
    build "$FIX/fox.wav" "$FIX/friday.wav" "$d/call.wav"
    local sum
    sum="$(shasum "$d/call.wav")"
    transcribe_only "$d/run.log" "$d/call.wav" --language en
    expect_line "$d/call.txt" You fox 0 5
    expect_line "$d/call.txt" "Speaker 1" friday 5 12
    [ "$(shasum "$d/call.wav")" = "$sum" ] || fail "the WAV changed"
    [ ! -e "$d/call.m4a" ] || fail "transcribe-only made an M4A"
}

case_transcribe_only_m4a() {
    local d="$1"
    build "$FIX/fox.wav" "$FIX/friday.wav" "$d/first.wav"
    afconvert -f m4af -d aac -b 128000 "$d/first.wav" "$d/call.m4a" || fail "couldn't make the M4A"
    rm -f "${d:?}/first.wav"
    transcribe_only "$d/run.log" "$d/call.m4a" --language en
    expect_line "$d/call.txt" You fox 0 5
    expect_line "$d/call.txt" "Speaker 1" friday 5 12
}

case_non_english() {
    local d="$1"
    if ! have_voice Thomas || ! have_voice Tingting; then
        echo "SKIPPED: the Thomas (French) and Tingting (Chinese) voices aren't installed"
        exit 77
    fi
    speak french "Nous livrerons le rapport vendredi prochain." Thomas
    speak chinese "我们下周五提交项目报告。" Tingting
    build "$FIX/french.wav" "$FIX/chinese.wav" "$d/call.wav"
    finish "$d/call"
    # Whisper's wording varies, and Chinese may come out in either script.
    expect_line "$d/call.txt" You "rapport|vendredi|livrer" 0 6
    expect_line "$d/call.txt" "Speaker 1" "报告|報告|周五|週五|星期五|提交|项目|項目" 5 14
}

# A new recording whose name is taken must be refused, and nothing may change.
case_output_refused() {
    local d="$1"
    printf 'old-m4a' > "$d/a.m4a"
    printf 'old-txt' > "$d/b.txt"
    printf '{}' > "$d/c.mcmeta.json"
    printf 'old-part' > "$d/d_part2.m4a"
    printf 'old-wav' > "$d/f.wav"
    local before
    before="$(cd "$d" && shasum ./* | shasum)"
    local out name
    # e_part2 is refused for its name alone, with no file in the way.
    for name in a b c d e_part2 f; do
        out="$d.refuse-$name.log"
        perl -e 'alarm shift; exec @ARGV' 60 "$BIN" --output "$d/$name.wav" --duration 2 --no-mic < /dev/null > "$out" 2>&1
        local rc=$?
        [ "$rc" -eq 1 ] || { echo "    FAIL: --output $name.wav exited $rc, expected 1"; show "$out"; exit 1; }
        expect_log "$out" "Can't record to"
    done
    [ "$(cd "$d" && shasum ./* | shasum)" = "$before" ] || fail "a file next to the refused names changed, appeared or went"
    [ "$(find "$d" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = "5" ] || fail "something new appeared next to the refused names"
}

case_script_flags_need_env() {
    local d="$1"
    build "$FIX/fox.wav" "$FIX/friday.wav" "$d/call.wav"
    # Taken, so that if the script flags were ignored the run would stop at the name check
    # and never reach capture.
    printf '{}' > "$d/taken.mcmeta.json"
    local before value out
    before="$(shasum "$d/call.wav")"
    for value in unset 0 true yes; do
        out="$d.env-$value.log"
        if [ "$value" = unset ]; then
            env -u MEETINGCAPTURE_E2E perl -e 'alarm shift; exec @ARGV' 60 "$BIN" \
                --two-track-mic "$FIX/fox.wav" --two-track-system "$FIX/friday.wav" --two-track-out "$d/made.wav" \
                --finish-recording "$d/call.wav" --model "$MODEL" --model-folder "$FOLDER" \
                --output "$d/taken.wav" --duration 2 --no-mic < /dev/null > "$out" 2>&1
        else
            MEETINGCAPTURE_E2E="$value" perl -e 'alarm shift; exec @ARGV' 60 "$BIN" \
                --two-track-mic "$FIX/fox.wav" --two-track-system "$FIX/friday.wav" --two-track-out "$d/made.wav" \
                --finish-recording "$d/call.wav" --model "$MODEL" --model-folder "$FOLDER" \
                --output "$d/taken.wav" --duration 2 --no-mic < /dev/null > "$out" 2>&1
        fi
        [ "$?" -eq 1 ] || { echo "    FAIL: with MEETINGCAPTURE_E2E=$value the run didn't stop at the name check"; show "$out"; exit 1; }
        expect_log "$out" "Can't record to"
        [ ! -e "$d/made.wav" ] || fail "MEETINGCAPTURE_E2E=$value: --two-track-* wrote a file"
        [ "$(shasum "$d/call.wav")" = "$before" ] || fail "MEETINGCAPTURE_E2E=$value: --finish-recording changed the WAV"
        [ ! -e "$d/call.m4a" ] && [ ! -e "$d/call.txt" ] || fail "MEETINGCAPTURE_E2E=$value: --finish-recording wrote output"
    done
}

case_existing_m4a_kept() {
    local d="$1"
    build "$FIX/fox.wav" "$FIX/friday.wav" "$d/call.wav"
    printf 'an earlier recording, not audio' > "$d/call.m4a"
    local before wav
    before="$(shasum "$d/call.m4a")"
    wav="$(shasum "$d/call.wav")"
    finish "$d/call" --language en
    [ "$(shasum "$d/call.m4a")" = "$before" ] || fail "the existing M4A was overwritten"
    [ "$(shasum "$d/call.wav")" = "$wav" ] || fail "the WAV changed or went"
    expect_log "$d/call.run.log" "call.m4a already exists"
    # The transcript still comes out, and the sidecar lists the WAV that stayed.
    expect_line "$d/call.txt" You fox 0 5
    expect_line "$d/call.txt" "Speaker 1" friday 5 12
    plutil -extract audioFiles json -o - "$d/call.mcmeta.json" | grep -q 'call.wav' || fail "the sidecar doesn't list the WAV that stayed"
    [ -z "$(find "$d" -mindepth 1 -maxdepth 1 -name '.*')" ] || fail "temporary files were left behind"
}

# ---------- runner ----------
now() { perl -MTime::HiRes=time -e 'printf "%.1f", time'; }

wanted() {  # name: true when no words were given, or the name contains one
    [ "$#" -eq 1 ] && return 0
    local name="$1" word
    shift
    for word in "$@"; do
        case "$name" in *"$word"*) return 0 ;; esac
    done
    return 1
}

PASSED=0 FAILED=0 KNOWN=0 SKIPPED=0
FAILED_NAMES=()
SUMMARY=()
TOTAL_START="$(now)"

for name in "${CASE_NAMES[@]}"; do
    wanted "$name" "$@" || continue
    dir="$CASES/$name"
    mkdir -p "$dir"
    start="$(now)"
    ( set -u; "case_${name//-/_}" "$dir" ) > "$dir.out" 2>&1
    rc=$?
    took="$(perl -e 'printf "%.1f", $ARGV[0] - $ARGV[1]' "$(now)" "$start")"
    reason="$(known_failure "$name")"
    if [ "$rc" -eq 0 ] && [ -z "$reason" ]; then
        status="PASS"
        PASSED=$((PASSED + 1))
    elif [ "$rc" -eq 77 ]; then
        status="SKIP"
        SKIPPED=$((SKIPPED + 1))
    elif [ "$rc" -ne 0 ] && [ -n "$reason" ]; then
        status="KNOWN FAIL"
        KNOWN=$((KNOWN + 1))
    elif [ "$rc" -eq 0 ]; then
        status="FAIL (it passes now, so remove the known-failure mark)"
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$name")
    else
        status="FAIL"
        FAILED=$((FAILED + 1))
        FAILED_NAMES+=("$name")
    fi
    printf '%-12s %-32s %6ss\n' "$status" "$name" "$took"
    SUMMARY+=("$(printf '%-12s %-32s %6ss' "$status" "$name" "$took")")
    case "$status" in
        PASS) ;;
        "KNOWN FAIL") echo "    known failure: $reason"; sed 's/^/    /' "$dir.out" ;;
        *) sed 's/^/    /' "$dir.out" ;;
    esac
done

echo
echo "e2e-full: $PASSED passed, $FAILED failed, $KNOWN known failures, $SKIPPED skipped, in $(perl -e 'printf "%.0f", $ARGV[0] - $ARGV[1]' "$(now)" "$TOTAL_START") s."
if [ "$FAILED" -gt 0 ]; then
    echo "e2e-full: FAILED: ${FAILED_NAMES[*]}" >&2
    exit 1
fi
exit 0
