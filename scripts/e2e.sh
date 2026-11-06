#!/usr/bin/env bash
# End to end without recording: a short spoken fixture goes through the real
# binary and a cached Whisper model. Skips with a message if no model is cached.
set -uo pipefail
ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 2

MODEL="openai_whisper-small.en"
FOLDER="$HOME/Documents/huggingface/models/argmaxinc/whisperkit-coreml/$MODEL"
if [ ! -d "$FOLDER" ]; then
    echo "e2e: SKIPPED, no cached model $MODEL. Nothing was downloaded."
    exit 0
fi

DIR="dev/tmp/fixtures"
mkdir -p "$DIR"
WAV="$DIR/e2e_fox.wav"
if [ ! -f "$WAV" ]; then
    say -o "$DIR/e2e_fox.aiff" "The quick brown fox jumps over the lazy dog. We will ship the report on Friday." || exit 1
    afconvert -f WAVE -d LEI16@48000 -c 1 "$DIR/e2e_fox.aiff" "$WAV" || exit 1
fi
rm -f "$DIR/e2e_fox.txt"

LOG="dev/tmp/e2e.log"
if ! perl -e 'alarm shift; exec @ARGV' 300 .build/debug/MeetingCaptureCLI \
        --transcribe-only "$WAV" --model "$MODEL" --model-folder "$FOLDER" --language en > "$LOG" 2>&1; then
    echo "e2e: FAILED, the binary exited with an error. See $LOG" >&2
    exit 1
fi
[ -s "$DIR/e2e_fox.txt" ] || { echo "e2e: FAILED, no transcript written. See $LOG" >&2; exit 1; }
for word in fox report friday; do
    grep -qi "$word" "$DIR/e2e_fox.txt" || { echo "e2e: FAILED, \"$word\" missing from the transcript." >&2; exit 1; }
done
grep -qE '^\[?[0-9]' "$DIR/e2e_fox.txt" || { echo "e2e: FAILED, transcript has no timestamps." >&2; exit 1; }
echo "e2e: ok, transcript has the expected words and timestamps."
