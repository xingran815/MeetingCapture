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
speak() {  # text, output wav
    say -o "$DIR/$2.aiff" "$1" || exit 1
    afconvert -f WAVE -d LEI16@48000 -c 1 "$DIR/$2.aiff" "$DIR/$2.wav" || exit 1
}
[ -f "$DIR/e2e_mic.wav" ] || speak "The quick brown fox jumps over the lazy dog." e2e_mic
[ -f "$DIR/e2e_system.wav" ] || speak "We will ship the report on Friday." e2e_system

# Each run starts from a fresh two-track recording, because the pipeline removes the WAV.
BASE="$DIR/e2e_call"
rm -f "$BASE".*
BIN=.build/debug/MeetingCaptureCLI
"$BIN" --two-track-mic "$DIR/e2e_mic.wav" --two-track-system "$DIR/e2e_system.wav" --two-track-out "$BASE.wav" \
    || { echo "e2e: FAILED, couldn't build the two-track fixture." >&2; exit 1; }
WAV_SIZE="$(wc -c < "$BASE.wav" | tr -d ' ')"

LOG="dev/tmp/e2e.log"
if ! perl -e 'alarm shift; exec @ARGV' 300 "$BIN" \
        --finish-recording "$BASE.wav" --model "$MODEL" --model-folder "$FOLDER" --language en > "$LOG" 2>&1; then
    echo "e2e: FAILED, the binary exited with an error. See $LOG" >&2
    exit 1
fi

TXT="$BASE.txt"
[ -s "$TXT" ] || { echo "e2e: FAILED, no transcript written. See $LOG" >&2; exit 1; }
[ -n "${CI:-}" ] && cat "$TXT"

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
    ' "$1" "$2" "$3" "$4" "$TXT" || { echo "e2e: FAILED, \"$2\" isn't under $1 between $3 and $4 s." >&2; exit 1; }
}
check "You" fox 0 5
check "Speaker 1" friday 5 12

# The WAV goes only once a good, smaller M4A exists.
[ ! -e "$BASE.wav" ] || { echo "e2e: FAILED, the WAV is still there. See $LOG" >&2; exit 1; }
[ -s "$BASE.m4a" ] || { echo "e2e: FAILED, no M4A. See $LOG" >&2; exit 1; }
M4A_SIZE="$(wc -c < "$BASE.m4a" | tr -d ' ')"
[ "$WAV_SIZE" -ge "$((8 * M4A_SIZE))" ] || {
    echo "e2e: FAILED, the M4A is $M4A_SIZE bytes against a $WAV_SIZE byte WAV, under 8x smaller." >&2
    exit 1
}
grep -q '"processed"' "$BASE.mcmeta.json" || { echo "e2e: FAILED, the sidecar isn't processed." >&2; exit 1; }
echo "e2e: ok, You and Speaker 1 at the right times, and the M4A is $((WAV_SIZE / M4A_SIZE))x smaller."
