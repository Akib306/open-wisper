# Open Wisper Swift changelog

## 1.0.0 — release candidate, November 14, 2026

The final Swift feature baseline before independent Rust development. See the [release record](../../docs/releases/swift-v1.0.0.md) for verification and pending live acceptance. This is a prepared candidate, not a published/tagged release.

### Added

- Offline English menu-bar dictation with a configurable toggle shortcut, explicit microphone capture, and a five-minute maximum recording limit.
- Bundled `tiny.en-q5_1`, `base.en` (default), and `small.en` Whisper models, plus custom-profile selection while idle.
- A solid bottom recording pill and separate Pebble window for Settings and memory-only transcript review.
- Cursor insertion with target/selection validation and a quiet Review/Copy fallback; explicit opt-out remains available.
- Cancellation and worker cleanup, safe temporary-audio recovery, validated atomic settings, single-instance GUI behavior, read-only delivery diagnostics, and engine peak-RSS reporting.
- Packaged third-party license notices, version 1.0.0/build 2 metadata, release review records, and a Rust implementation handoff.

### Fixed

- Cancelling at the preparation, finalization, or transcription transition no longer starts the next operation after the session has been revoked.
- Clearing an engine profile during verification no longer leaves the app stuck in its checking state.
- Bottom-pill review actions stay synchronized with Copy and Dismiss in Pebble. Failed Copy keeps recovery available; closing idle review clears its transcript.
- Cancellation feedback remains visible after returning to idle, and completion timers from earlier sessions cannot hide a new recording indicator.

The pill/lifecycle fixes were implemented in the preceding `332e1df` baseline and are included in this candidate. Model selection remains experimental; live editor/device/display acceptance and controlled comparative benchmarks remain open. No automatic updater is enabled.
