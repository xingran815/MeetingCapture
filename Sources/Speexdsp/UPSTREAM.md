# Vendored speexdsp

Source: https://github.com/xiph/speexdsp
Pinned commit: `7a158783df74efe7c2d1c6ee8363c1e695c71226` (2025-07-05)
License: BSD-3 (Xiph.Org Foundation), see `LICENSE`.

Only the files needed for the acoustic echo canceller (`speex_echo.h`) and
preprocessor (`speex_preprocess.h`) running on top of the KissFFT backend are
vendored:

- C sources: `mdf.c`, `preprocess.c`, `fftwrap.c`, `kiss_fft.c`, `kiss_fftr.c`,
  `filterbank.c`
- Private headers: `arch.h`, `_kiss_fft_guts.h`, `fftwrap.h`, `filterbank.h`,
  `fixed_generic.h`, `kiss_fft.h`, `kiss_fftr.h`, `math_approx.h`,
  `os_support.h`, `pseudofloat.h`
- Public headers (under `include/speex/`): `speex_echo.h`, `speex_preprocess.h`,
  `speexdsp_types.h`

Build flags (set in `Package.swift`'s `cSettings`):

- `FLOATING_POINT` — use float pipeline; we don't need fixed-point.
- `USE_KISS_FFT` — KissFFT FFT backend (portable C, no Accelerate/MKL/FFTW
  dependency, builds clean on Apple Silicon ARM64).

To update: re-clone xiph/speexdsp at a newer commit, copy the same set of
files, update the pinned commit hash above, and re-run `swift build`.
