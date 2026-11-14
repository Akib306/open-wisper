# Open Wisper

Offline dictation for macOS. Record with a keyboard shortcut and insert the transcript into the text field where you stopped recording. Audio is transcribed locally; no account or service key is required.

## Download for macOS

**[Download Open Wisper Swift — Apple Silicon](https://github.com/Akib306/open-wisper/releases/download/swift-v1.0.0-rc.1/Open-Wisper-Swift-1.0.0-rc.1-macos-arm64.zip)**

Requires an Apple Silicon Mac (M-series) with macOS 14 or later. This is the **1.0.0 release candidate, build 2**. The ZIP is approximately 610 MB and contains the app, speech engine, and all three English models. You do not need Xcode, Swift, Python, Homebrew, or separate model downloads.

1. Download the app ZIP above and double-click it to extract **Open Wisper Swift.app**.
2. Drag **Open Wisper Swift.app** into **Applications**, then open it there. Its controls live in the menu bar.
3. Allow microphone access when you first record. To insert into other apps, choose **Enable cursor insertion…** and enable Open Wisper Swift in **System Settings → Privacy & Security → Accessibility**.
4. Place your cursor in a text field. Press **Command–Shift–Space** to start recording and again to stop. If the destination cannot be used safely, Review/Copy keeps the transcript available.

This preview is ad-hoc signed and is **not notarized by Apple**. If macOS blocks the first launch and you choose to trust this build, open **System Settings → Privacy & Security → Open Anyway**, then confirm Open. See [Apple's guidance](https://support.apple.com/en-us/102445). No Terminal commands or system-wide security changes are needed.

[Release notes and checksum](https://github.com/Akib306/open-wisper/releases/tag/swift-v1.0.0-rc.1) · [App guide](native/swift/README.md#use) · [Changelog](native/swift/CHANGELOG.md)

In the release's Assets list, choose **Open-Wisper-Swift-1.0.0-rc.1-macos-arm64.zip**. GitHub's **Source code (zip)** and **Source code (tar.gz)** downloads contain source code rather than the app. This build is for Apple Silicon; an Intel download is not available.

The default model is `base.en`; Settings also offers `tiny.en-q5_1` and `small.en`. Model comparisons and the pending live acceptance checks are recorded in the [release record](docs/releases/swift-v1.0.0.md). Rust is the next independent application; the Electron MVP remains a reference.

## For developers

Building from source is optional. See the [Swift developer guide](native/swift/README.md#build-from-source-developers) for toolchain requirements, engine provisioning, packaging, and tests.

- [Swift 1.0.0 release record](docs/releases/swift-v1.0.0.md): reviewed scope, fixes, downloadable artifact, and remaining live acceptance checks.
- [Swift verification status](docs/swift-status.md): completed checks and remaining release gates.
- [Rust handoff](docs/rust-handoff.md) and [native implementation plan](docs/native-plan.md): next implementation slices, architecture, and comparison gates.
- [Native v1 behavior contract](docs/native-contract.md): shared behavior and acceptance scenarios for both implementations.
- [UI decision](docs/decisions/0002-bottom-pill.md): bottom recording pill and separate Pebble window.
- [macOS updates and permissions](docs/macos-updates.md): signing decisions and the deferred OTA update workflow.
- [Installed Wispr Flow investigation](docs/research/wispr-flow.md): artifact-backed findings and remaining unknowns.
- [Electron MVP](mvp/README.md) and [historical measurements](mvp/BENCHMARK.md): reference implementation and preliminary smoke measurements.

The native tracks share behavior specifications and an exact, hash-recorded speech-engine profile. The Swift app has no Electron or Rust dependency. No Wispr source, branding, service credentials, or private protocols are used.
