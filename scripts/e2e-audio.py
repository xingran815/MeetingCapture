#!/usr/bin/env python3
"""Invented audio for scripts/e2e-full.sh. Mono 16-bit 48 kHz WAVs only, standard library only.

  e2e-audio.py silence OUT SECONDS
  e2e-audio.py noise   OUT SECONDS AMPLITUDE [SEED]   white noise, AMPLITUDE of full scale (0.003 is quiet)
  e2e-audio.py softmix OUT SPEECH PEAK RMS SEED PAD   speech scaled so its loudest 100 ms window, with the noise, is
                                                      PEAK, over Gaussian noise of RMS, PAD seconds of noise each side
  e2e-audio.py cat     OUT IN...                      files joined end to end
  e2e-audio.py crash   FILE                           makes a WAV declare no audio, as a crash leaves it
"""
import array
import math
import random
import sys
import wave

RATE = 48_000


def read(path):
    with wave.open(path, "rb") as w:
        if (w.getnchannels(), w.getsampwidth(), w.getframerate()) != (1, 2, RATE):
            sys.exit(f"{path}: needs mono 16-bit {RATE} Hz")
        samples = array.array("h")
        samples.frombytes(w.readframes(w.getnframes()))
        return samples


def write(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(samples.tobytes())


def main(argv):
    if sys.byteorder != "little":
        sys.exit("little-endian machines only")
    cmd, args = argv[0], argv[1:]
    if cmd == "silence":
        write(args[0], array.array("h", bytes(2 * int(float(args[1]) * RATE))))
    elif cmd == "noise":
        rng = random.Random(int(args[3]) if len(args) > 3 else 1)
        peak = float(args[2]) * 32767
        count = int(float(args[1]) * RATE)
        write(args[0], array.array("h", (int(rng.uniform(-peak, peak)) for _ in range(count))))
    elif cmd == "softmix":
        out, speech_path, peak, rms, seed, pad = args[0], args[1], float(args[2]), float(args[3]), int(args[4]), float(args[5])
        if peak <= rms:
            sys.exit("PEAK must be above RMS")
        speech = read(speech_path)
        window = RATE // 10
        loudest = 0.0
        for start in range(0, max(1, len(speech) - window + 1), window // 2):
            chunk = speech[start:start + window]
            loudest = max(loudest, math.sqrt(sum(x * x for x in chunk) / len(chunk)) / 32768)
        if loudest == 0:
            sys.exit(f"{speech_path}: silent")
        # Independent powers add: peak^2 = speech^2 + rms^2.
        gain = math.sqrt(peak * peak - rms * rms) / loudest
        rng = random.Random(seed)
        padding = int(pad * RATE)
        total = padding + len(speech) + padding
        mixed = array.array("h")
        for i in range(total):
            value = rng.gauss(0, rms) * 32768
            if padding <= i < padding + len(speech):
                value += speech[i - padding] * gain
            mixed.append(max(-32768, min(32767, int(value))))
        write(out, mixed)
    elif cmd == "cat":
        joined = array.array("h")
        for path in args[1:]:
            joined.extend(read(path))
        write(args[0], joined)
    elif cmd == "crash":
        with open(args[0], "r+b") as f:
            head = f.read(4096)
            at = head.find(b"data")
            if at < 0:
                sys.exit(f"{args[0]}: no data chunk in the first 4 KiB")
            f.seek(at + 4)
            f.write(bytes(4))
    else:
        sys.exit(__doc__)


main(sys.argv[1:])
