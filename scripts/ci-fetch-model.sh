#!/usr/bin/env bash
# Downloads the small public Whisper model CI uses, at a pinned revision, and prints
# its folder. No token needed. The CI cache is keyed on this file, so changing the
# revision here refreshes the cache. Progress goes to stderr.
set -euo pipefail

REVISION="0f63a7800b00dd0226abd051b906c246e1907482"
MODEL="openai_whisper-tiny"
BASE="https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/$REVISION"
API="https://huggingface.co/api/models/argmaxinc/whisperkit-coreml/tree/$REVISION/$MODEL?recursive=1"
FOLDER="$HOME/whisper-ci/$MODEL"

if [ -f "$FOLDER/.complete" ]; then
    echo "model: cached at this revision" >&2
    printf '%s\n' "$FOLDER"
    exit 0
fi

rm -rf "$FOLDER"
mkdir -p "$FOLDER"
curl --fail --silent --show-error --retry 3 "$API" \
    | perl -MJSON::PP -0777 -ne 'for (@{decode_json($_)}) { print "$_->{path}\n" if $_->{type} eq "file" }' \
    > "$FOLDER/.files"
[ -s "$FOLDER/.files" ] || { echo "model: no files listed" >&2; exit 1; }

while IFS= read -r path; do
    target="$HOME/whisper-ci/$path"
    mkdir -p "$(dirname "$target")"
    curl --fail --silent --show-error --location --retry 3 -o "$target" "$BASE/$path"
done < "$FOLDER/.files"

touch "$FOLDER/.complete"
echo "model: downloaded $(wc -l < "$FOLDER/.files" | tr -d ' ') files" >&2
printf '%s\n' "$FOLDER"
