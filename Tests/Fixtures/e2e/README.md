# E2E speech fixtures

`e2e_mic.caf` and `e2e_system.caf` are two short synthetic voice clips, mono AAC in a CAF
container. The text is invented: "The quick brown fox jumps over the lazy dog." (mic) and
"We will ship the report on Friday." (system). `scripts/e2e.sh` decodes them to WAV, so a
CI runner never has to run `say`, which sometimes writes silence there.

`.gitignore` and `scripts/sweep.sh` reject audio and video files everywhere, in any common
container, because those may hold real recordings. These two files are the only exception,
by exact name, approved by the user. Don't add another file here without asking.

Made once on a Mac with:

    say -o mic.aiff "The quick brown fox jumps over the lazy dog."
    say -o system.aiff "We will ship the report on Friday."
    afconvert -f caff -d aac -b 64000 -c 1 mic.aiff e2e_mic.caf
    afconvert -f caff -d aac -b 64000 -c 1 system.aiff e2e_system.caf
