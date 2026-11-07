#!/usr/bin/env bash
# End to end without recording: a short spoken fixture goes through the real
# binary and a cached Whisper model. Skips with a message if no model is cached,
# but on CI a missing model is a failure. E2E_MODEL and E2E_MODEL_FOLDER override.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

MODEL="${E2E_MODEL:-openai_whisper-small}"
FOLDER="${E2E_MODEL_FOLDER:-$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml/$MODEL}"
if [ ! -d "$FOLDER" ]; then
    if [ -n "${CI:-}" ]; then
        echo "e2e: FAILED, no model at $FOLDER. A skip doesn't count on CI." >&2
        exit 1
    fi
    echo "e2e: SKIPPED, no cached model $MODEL. Nothing was downloaded."
    exit 0
fi

DIR="dev/tmp/fixtures"
mkdir -p "$DIR"
LOG="dev/tmp/e2e.log"
TXT=""
# Every failure after the fixtures goes through here. On CI it also shows the log tail and the
# transcript, because a CI failure can't be reproduced by hand (twice it left only a blank transcript).
fail() {  # message
    echo "e2e: FAILED, $1" >&2
    if [ -n "${CI:-}" ]; then
        { echo "--- last 60 lines of $LOG"; tail -n 60 "$LOG" 2>/dev/null
          echo "--- transcript ${TXT:-}"; cat "${TXT:-/dev/null}" 2>/dev/null; echo "---"; } >&2
    fi
    exit 1
}
speak() {  # text, output wav
    say -o "$DIR/$2.aiff" "$1" || exit 1
    afconvert -f WAVE -d LEI16@48000 -c 1 "$DIR/$2.aiff" "$DIR/$2.wav" || exit 1
}
# Peak |sample| of a 16-bit WAV's data chunk. Prints 0 if it can't parse (counts as silent).
peak_of() {  # wav
    perl -e '
        open(my $h, "<:raw", $ARGV[0]) or do { print 0; exit };
        local $/; my $d = <$h>; my $p = 12; my $max = 0;
        while ($p + 8 <= length($d)) {
            my ($id, $n) = unpack("a4 V", substr($d, $p, 8));
            if ($id eq "data") {
                $n = length($d) - $p - 8 if $p + 8 + $n > length($d);
                for my $s (unpack("s<*", substr($d, $p + 8, $n - ($n % 2)))) {
                    my $a = $s < 0 ? -$s : $s; $max = $a if $a > $max;
                }
                last;
            }
            $p += 8 + $n + ($n % 2);
        }
        print $max;
    ' "$1"
}
dur_of() {  # wav, seconds, integer part; 0 if afinfo can't read it
    local out
    out="$(afinfo "$1" 2>&1)"
    echo "$out" | awk '/estimated duration/ { printf "%d", $3; found=1 } END { if (!found) printf "0" }'
}
# Make a fixture if missing or silent (a cached one too). `say` on a headless runner may write
# silent audio; not proven, so this retries and says what it saw.
ensure_fixture() {  # text, name
    local try=0 dur peak
    while :; do
        if [ -f "$DIR/$2.wav" ]; then
            dur="$(dur_of "$DIR/$2.wav")"; peak="$(peak_of "$DIR/$2.wav")"
            if [ "$dur" -ge 1 ] && [ "$peak" -ge 1000 ]; then
                echo "e2e: fixture $2 duration=${dur}s peak=$peak"
                return 0
            fi
            echo "e2e: fixture $2 is silent or short (duration=${dur}s peak=$peak), regenerating." >&2
            rm -f "$DIR/$2.wav" "$DIR/$2.aiff"
        fi
        if [ "$try" -ge 3 ]; then
            echo "e2e: FAILED, say wrote silent audio: fixture $2, duration ${dur:-?} s, peak ${peak:-?} of 32767 (floor 1000), after 3 tries." >&2
            exit 1
        fi
        try=$((try + 1))
        speak "$1" "$2"
        dur="$(dur_of "$DIR/$2.wav")"; peak="$(peak_of "$DIR/$2.wav")"
        if [ "$dur" -lt 1 ] || [ "$peak" -lt 1000 ]; then
            echo "e2e: fixture $2 try $try: duration=${dur}s peak=$peak, too quiet." >&2
            rm -f "$DIR/$2.wav" "$DIR/$2.aiff"
            sleep 1
            continue
        fi
        echo "e2e: fixture $2 duration=${dur}s peak=$peak"
        return 0
    done
}
ensure_fixture "The quick brown fox jumps over the lazy dog." e2e_mic
ensure_fixture "We will ship the report on Friday." e2e_system

# Each run starts from a fresh two-track recording, because the pipeline removes the WAV.
BASE="$DIR/e2e_call"
rm -f "$BASE".*
BIN=.build/debug/MeetingCaptureCLI
# The script-only flags overwrite and delete by path, so they need this to be set.
export MEETINGCAPTURE_E2E=1
"$BIN" --two-track-mic "$DIR/e2e_mic.wav" --two-track-system "$DIR/e2e_system.wav" --two-track-out "$BASE.wav" \
    || fail "couldn't build the two-track fixture."
WAV_SIZE="$(wc -c < "$BASE.wav" | tr -d ' ')"

if ! perl -e 'alarm shift; exec @ARGV' 300 "$BIN" \
        --finish-recording "$BASE.wav" --model "$MODEL" --model-folder "$FOLDER" --language en > "$LOG" 2>&1; then
    fail "the binary exited with an error. See $LOG"
fi

TXT="$BASE.txt"
[ -s "$TXT" ] || fail "no transcript written. See $LOG"
if [ -n "${CI:-}" ]; then cat "$TXT"; fi

# Words reach the right speaker, at the right time: the mic talks first, the system from 6 s.
# Finding (M3): VAD chunking lost speech that followed silence, and the system track
# here opens with 6 s of it, so this also proves that speech survives.
check() {  # label, word, first and last second allowed
    perl -e '
        my ($label, $word, $from, $to) = @ARGV[0..3];
        open(my $h, "<", $ARGV[4]) or exit 1;
        while (<$h>) {
            next unless /^\[(\d+):(\d+):(\d+)\] \Q$label\E: .*\Q$word\E/i;
            my $at = $1 * 3600 + $2 * 60 + $3;
            exit(($at >= $from && $at <= $to) ? 0 : 2);
        }
        exit 3;
    ' "$1" "$2" "$3" "$4" "$TXT" || fail "\"$2\" isn't under $1 between $3 and $4 s."
}
check "You" fox 0 5
check "Speaker 1" friday 5 12

# The WAV goes only once a good, smaller M4A exists.
[ ! -e "$BASE.wav" ] || fail "the WAV is still there. See $LOG"
[ -s "$BASE.m4a" ] || fail "no M4A. See $LOG"
M4A_SIZE="$(wc -c < "$BASE.m4a" | tr -d ' ')"
[ "$WAV_SIZE" -ge "$((8 * M4A_SIZE))" ] ||
    fail "the M4A is $M4A_SIZE bytes against a $WAV_SIZE byte WAV, under 8x smaller."
grep -q '"processed"' "$BASE.mcmeta.json" || fail "the sidecar isn't processed."
echo "e2e: ok, You and Speaker 1 at the right times, and the M4A is $((WAV_SIZE / M4A_SIZE))x smaller."
