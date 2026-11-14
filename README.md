# Open Wisper

An open-source, local-first macOS dictation project. The native Swift menu-bar app is preparing its 1.0.0 release baseline; the Electron MVP remains a reference. The next track is an independent Rust application.

**Experimental:** The native app bundles three offline Whisper models: `tiny.en-q5_1`, `base.en` (default), and `small.en`. Choose a model in Settings while dictation is idle. These remain evaluation builds; no controlled accuracy, latency, or memory comparison is claimed yet.

## Start here

- [Native Swift app](native/swift/README.md): build, launch, local engine setup, and usage.
- [Swift 1.0.0 release record](docs/releases/swift-v1.0.0.md): reviewed scope, fixes, release procedure, and remaining live acceptance checks.
- [Swift changelog](native/swift/CHANGELOG.md) and [Rust handoff](docs/rust-handoff.md): the final Swift feature baseline and next implementation slices.
- [Swift verification status](docs/swift-status.md): completed checks and remaining release gates.
- [macOS updates and permissions](docs/macos-updates.md): stable signing and the proposed OTA update workflow.
- [Installed Wispr Flow investigation](docs/research/wispr-flow.md): artifact-backed findings, provenance, and remaining unknowns.
- [Rust and Swift implementation plan](docs/native-plan.md): architecture decisions, implementation tickets, and comparison gates.
- [Native v1 behavior contract](docs/native-contract.md): shared behavior and acceptance scenarios for both implementations.
- [Accepted UI decision](docs/decisions/0002-bottom-pill.md): Swift's bottom pill and separate Pebble window, also selected for planned Rust. Native verification results and remaining hardware/focus checks are recorded separately.
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
