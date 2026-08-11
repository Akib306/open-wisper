# MVP baseline — 2 August 2026

Initial measurements from the development Mac, intended as the Electron side of the later Swift/AppKit comparison.

## Environment

- Apple Silicon macOS 26.5
- Electron 43.2.0
- `whisper.cpp` v1.8.1, CPU/Accelerate build with Metal disabled
- `tiny.en-q5_1`, 31.6 MB model
- Included 11.0-second `samples/jfk.wav` reference audio

## Results

| Measurement | Result |
| --- | ---: |
| Packaged app size, uncompressed | 603 MB |
| Bundled whisper runtime + model | 33 MB |
| Electron idle processes | 4 |
| Electron idle RSS, summed | 425.1 MB |
| whisper worker peak RSS | 136.5 MB |
| 11-second transcription wall time | 0.39 s |
| Real-time factor | 0.035× |

The idle RSS total came from the main, GPU, utility, and renderer processes immediately after the unsigned packaged app started. The worker peak came from `/usr/bin/time -l`. These are one-run smoke numbers, not a statistically controlled comparison.

## Interpretation

The tiny model is fast and compact; the dominant idle cost is Electron itself. Because the app starts `whisper-cli` only for an utterance and then exits it, the roughly 136 MB worker footprint is temporary. A native Swift/AppKit shell should be able to keep the same worker speed while substantially reducing the roughly 425 MB idle baseline.

For the actual comparison, repeat three warm runs per app, use the same audio and exact model binary, and report medians. Also compare with `base.en-q5_0`, where accuracy improves but worker memory becomes more prominent.
