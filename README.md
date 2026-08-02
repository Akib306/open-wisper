# Open Wisper MVP

A macOS-first, local dictation MVP built with Electron, TypeScript, and `whisper.cpp`. It is intentionally small and dependency-light so you can compare its shell overhead against the planned Swift/AppKit version while keeping the transcription engine the same.

## What works

- Menu-bar app with a control window.
- Global `Command + Shift + Space` shortcut to start and stop recording.
- Microphone capture in Electron, converted in memory to mono 16 kHz PCM WAV.
- Local English transcription through a short-lived `whisper.cpp` worker.
- Clipboard delivery and optional paste back into the app that was active when recording started.
- Live combined memory reporting for every Electron process plus the active transcription worker.
- Last-run real-time factor (`transcription time ÷ audio duration`) and peak RAM.
- Manual paths for using any compatible `whisper-cli` binary or `.bin` model.

Audio is written only to a private temporary directory for transcription and is removed immediately afterward. No network request is made by the running app.

## First run

Requirements: macOS on Apple Silicon, Node.js 22+, pnpm, Xcode Command Line Tools, Homebrew, and CMake.

```bash
pnpm install
brew install cmake          # only if `cmake` is not already installed
pnpm setup:whisper          # builds CPU-only whisper.cpp and downloads tiny.en-q5_1
pnpm dev
```

On first launch, allow Microphone access. For automatic paste, also allow the Electron/Open Wisper process in **System Settings → Privacy & Security → Accessibility**. Without Accessibility access, every successful transcript is still copied to the clipboard.

The setup script pins `whisper.cpp` v1.8.1 and builds with Metal off so the initial memory comparison favors predictable CPU-only measurements. Override the model or source version when needed:

```bash
bash scripts/setup-whisper.sh base.en-q5_0
WHISPER_CPP_VERSION=v1.8.1 bash scripts/setup-whisper.sh tiny.en-q5_1
```

After switching models, choose the new `.bin` file in **Engine & behavior**.

## Development

```bash
pnpm dev          # compile and run
pnpm test         # compile and run audio pipeline tests
pnpm build        # compile only
pnpm package:mac  # unsigned local .app in dist/mac-arm64
```

The packaged build is for local use and does not require the paid Apple Developer Program. Gatekeeper warnings are expected for an unsigned build copied to another Mac.

## Benchmarking against Swift

Use the same Mac, model file, audio clip, and CPU/Metal setting in both apps. For each app, record these separately:

1. Idle working set after launch and after one minute.
2. Recording working set after ten seconds of speech.
3. Peak working set during transcription.
4. Real-time factor for the same 10–20 second utterance.
5. Time until the result reaches the clipboard.

The four counters in the window update once per second. “Memory now” and “Peak memory” aggregate Electron's main, renderer, GPU/utility processes, and the active `whisper-cli` process. macOS may retain shared pages differently between runs, so repeat each measurement three times and compare medians.

Expected result: transcription speed should be close when both apps invoke the same `whisper.cpp` binary, while Electron should have clearly higher idle RAM than a native AppKit shell. This MVP deliberately exits `whisper-cli` after each utterance, so the model consumes no idle memory.

## Project map

```text
src/main.ts       Electron lifecycle, tray, shortcut, whisper worker, paste, metrics
src/preload.ts    Narrow context-isolated renderer API
src/renderer.ts   Recording workflow and interface state
src/audio.ts      PCM merge, resampling, WAV encoding, level metering
scripts/          Build helpers and reproducible whisper.cpp setup
tests/            Node tests for the audio conversion pipeline
```

## MVP limitations

- Manual stop only; silence/VAD is intentionally deferred.
- English-only model and no text rewriting beyond whitespace cleanup.
- Auto-paste is macOS-only and uses System Events, so Accessibility permission is required.
- `ScriptProcessorNode` keeps the capture implementation compact; an AudioWorklet is the next step if capture profiling shows renderer stalls.
- The default tiny quantized model prioritizes memory over accuracy. Use `base.en-q5_0` for the next quality comparison.
