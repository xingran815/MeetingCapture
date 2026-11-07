// Runs the vendored Speex echo canceller over raw int16 mic and reference files, the
// way EchoCanceller.swift does live. Lab only: argv is mic ref out tail_samples preprocess.
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "speex/speex_echo.h"
#include "speex/speex_preprocess.h"

int main(int argc, char **argv) {
    if (argc < 6) return 2;
    FILE *m = fopen(argv[1], "rb"), *r = fopen(argv[2], "rb"), *o = fopen(argv[3], "wb");
    if (!m || !r || !o) return 3;
    int frame = 480, rate = 48000, tail = atoi(argv[4]), pp = atoi(argv[5]), on = 1;
    SpeexEchoState *e = speex_echo_state_init(frame, tail);
    SpeexPreprocessState *p = speex_preprocess_state_init(frame, rate);
    speex_echo_ctl(e, SPEEX_ECHO_SET_SAMPLING_RATE, &rate);
    speex_preprocess_ctl(p, SPEEX_PREPROCESS_SET_ECHO_STATE, e);
    speex_preprocess_ctl(p, SPEEX_PREPROCESS_SET_DENOISE, &on);
    int16_t a[480], b[480], c[480];
    while (fread(a, 2, frame, m) == (size_t)frame && fread(b, 2, frame, r) == (size_t)frame) {
        speex_echo_cancellation(e, a, b, c);
        if (pp) speex_preprocess_run(p, c);
        fwrite(c, 2, frame, o);
    }
    fclose(o);
    return 0;
}
