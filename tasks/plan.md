# Rust application implementation

## Goal and architecture

Implement the independent macOS Rust application specified by `docs/rust-handoff.md` and `docs/native-contract.md`, under `native/rust`. Keep Swift and Electron unchanged. Use native AppKit surfaces, not a WebView, with a separate Rust bundle identity and preferences. Reuse the existing verified whisper.cpp artifacts and packaging utility rather than rebuilding or downloading models unnecessarily.

## Implementation boundaries

1. **Core (Terra, high):** `native/rust/crates/wisper-core/**`. Own the serialized session state machine, validated settings, engine manifest validation, supervised transcription, private workspaces, and unit tests. No macOS UI dependencies.
2. **Platform (Sol, medium):** `native/rust/crates/wisper-platform/**`. Own Rust macOS capture, permissions, global shortcut, focus-safe delivery, clipboard and single-instance adapters. Standalone public API; no dependency on the core crate. Conservative Review/Copy fallback is mandatory whenever target safety cannot be established.
3. **Application (after both APIs exist):** workspace root, `crates/open-wisper/**`, resources, packaging, and native/rust README. Own main-thread AppKit UI and integration; no rewriting the two upstream crates without coordination.

The core/platform crates can be implemented concurrently. The application ticket depends on both. The main agent accepts each boundary, reviews security and cancellation, then performs build/test/package validation.

## Acceptance criteria

- Cargo tests cover stale callbacks, cancellation, exactly-once delivery, settings and manifest rejection, bounded process output and timeout, private cleanup, and audio/delivery policy where feasible.
- Native application compiles independently of Swift; idle launch does not record or open a window.
- Menu, configurable registered toggle shortcut, nonactivating bottom indicator and explicit Pebble Review/Settings provide the dictation workflow.
- Explicit capture produces mono 16 kHz PCM16 WAV, invokes the pinned offline worker, and preserves Review/Copy on unsafe delivery.
- Cancellation/quit invalidate delivery and terminate/reap the owned worker. No shell execution of transcripts, automatic Return, content logs, or persistent transcript history.
- Packaged identity is `dev.akib.openwisper.rust`, with microphone usage description and third-party notices; packaging reuses verified model cache.
- Documentation distinguishes automated validation from unperformed live microphone, permission and editor acceptance checks; no performance or release-conformance claims without evidence.

## Constraints and risks

- No commits, pushes, new branches, signing-account setup, permission changes, or live microphone/editor interaction during implementation.
- Rust tooling is absent on this machine; use a temporary Rust installation in `/tmp/open-wisper-cargo` and `/tmp/open-wisper-rustup` for validation, leaving the user's shell configuration untouched.
- Baseline accounts/MFA: zero. The separate Rust app requires its own macOS microphone grant and Accessibility setup if insertion is enabled; ad-hoc rebuilds can require renewed consent.
- Fail closed for unknown AX ancestry, focus, selection or process identity. Do not claim Command-V/AX success proves insertion. Explicitly document incomplete native conformance gates.
