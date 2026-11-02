# Open Wisper

An open-source, local-first macOS dictation project. A native Swift menu-bar application and the Electron reference MVP are implemented. An independent Rust application remains planned.

**Experimental:** The native app and its current `small.en` configuration are evaluation builds, not a validated final model choice. In the next iteration we will switch to `base.en` and test recognition quality, transcription latency, and peak memory using the same recordings. No controlled `small.en`-versus-`base.en` results are claimed yet.

## Start here

- [Native Swift app](native/swift/README.md): build, launch, local engine setup, and usage.
- [Swift verification status](docs/swift-status.md): completed checks and remaining release gates.
- [Installed Wispr Flow investigation](docs/research/wispr-flow.md): artifact-backed findings, provenance, and remaining unknowns.
- [Rust and Swift implementation plan](docs/native-plan.md): architecture decisions, implementation tickets, and comparison gates.
- [Native v1 behavior contract](docs/native-contract.md): shared behavior and acceptance scenarios for both implementations.
- [Existing Electron MVP](mvp/README.md): setup and current functionality.
- [Historical MVP measurements](mvp/BENCHMARK.md): preliminary smoke measurements, not controlled native comparisons.

The native tracks share behavior specifications and an exact, hash-recorded speech-engine profile. The Swift app does not require a Rust or Electron application core. No Wispr source, branding, service credentials, or private protocols are used in the implementation.

To build the Swift app using the engine already installed for the MVP:

```sh
python3 tools/engine/provision.py
bash native/swift/scripts/build-app.sh
open 'native/swift/dist/Open Wisper Swift.app'
```

The installed apps are **Open Wisper Swift** and **Open Wisper Electron** in `/Applications`. Each variant allows one running instance per user; opening another copy returns to its existing instance. Their settings and bundle IDs remain separate.
