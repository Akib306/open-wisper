# Rust developer preview verification

Date: November 14, 2026. This is an independent implementation under
[`native/rust`](../native/rust/README.md), not a Swift wrapper or WebView. It is a
developer preview, not a conformance-certified replacement for the Swift release.

## Implemented

- Native AppKit menu-bar app, explicit Ready/Review/Settings Pebble window and
  nonactivating bottom pill; idle launch has no capture or permission request.
- Rust-owned CoreAudio capture with a preallocated bounded callback handoff,
  worker-side anti-aliased conversion and final-frame flush to mono 16 kHz PCM16.
- Serialized generation-tagged coordination, one validation/inference worker,
  cancellation and stale-result rejection, one-time delivery authorization,
  direct-argv bounded process supervision, deadlines and TERM/KILL/reaping.
- Strict pinned engine profiles and artifact hashes; bundled `base.en` default,
  `tiny.en-q5_1` and `small.en`, with explicit custom-profile support.
- Focus/process/selection/security-checked native selected-text delivery and
  explicit Review/Copy. Successful AX requests are not called verified insertion.
- Atomic settings, transactional registered shortcuts, private owned WAV sessions,
  a lifetime instance lock and separate `dev.akib.openwisper.rust` identity.
- Cached-model packaging, nested-worker digest verification, third-party notices
  and ad-hoc signing without an Apple account or changes to the Swift app.

## Automated validation

On Apple Silicon, Rust 1.100.0, with `MACOSX_DEPLOYMENT_TARGET=14.0`:

- `cargo test --locked --workspace`: **26 passed** (7 core, 14 platform, 5 app).
- `cargo fmt --all --check`: passed.
- `cargo clippy --locked --workspace --all-targets -- -D warnings`: passed.
- Packaging safety tests: **2 passed**.
- Release build, content-free CLI self-check, source-profile validation and all
  three packaged engine/model profile checks passed during implementation.
- Packaged plist and strict/deep code-signature checks passed during implementation;
  the executable is arm64 with a macOS 14.0 deployment target.

The main agent independently reran tests, formatting, lint, release build, source
profile validation and packaging checks before handoff.
Tests compile/link native frameworks but never register a live shortcut, request
permissions, start the microphone, inspect actual editor contents or inject input.
No Rust-versus-Swift accuracy, memory, latency or performance result is claimed.

## Independent review follow-up

- Failed transcription/WAV operations now explicitly attempt cleanup and report
  any cleanup failure separately. Two regression tests cover confirmed cleanup
  and an interrupted workspace whose audio cannot safely be removed.
- Ready explains that stopping in the activated app uses Review/Copy. Use the
  nonactivating pill or shortcut with the editor focused for cursor insertion;
  the app never guesses or reactivates a previous editor.
- A suspected resampler filter-delay truncation was not reproduced. A new
  synthetic impulse test checks both recording boundaries at seven input rates
  from 8 kHz to 192 kHz, including 44.1 and 48 kHz. Impulse peaks remain within
  two output samples of their expected positions, including immediately before
  Stop. Existing final-partial-buffer, anti-aliasing and duration tests also pass;
  no speculative filter-delay adjustment was made.
- Timer-driven application-loop exit and native teardown still need live testing;
  source inspection alone does not certify them.

## Known deviations from the target contract

- **Automatic browser Paste is not implemented.** Web/AXWebArea targets fall back
  to Review/Copy, never an unvalidated selected-text write. Native unsupported,
  secure, changed or unknown targets also fall back. Automatic multiline delivery
  is restricted conservatively; see the platform guide for policy.
- **Automatic crash-audio recovery is not implemented.** Normal exit/cancel removes
  only verified owned files. A force-kill/crash can leave private session audio;
  startup reports leftovers without reading or recursively deleting them. Stop
  the Rust app and manually inspect/remove only interrupted Rust session folders.
- There is no persistent transcript history, updater, notarized Rust download,
  measured resource dashboard or supported Windows/Linux native application.

## Pending manual release gates

- [ ] Packaged launch, idle invisibility and second-instance behavior.
- [ ] Microphone allow/deny/revoke, explicit Accessibility setup and shortcut conflicts.
- [ ] Real capture, five-minute automatic Stop, overflow/device changes and teardown.
- [ ] End-to-end offline dictation with original or consented synthetic fixtures.
- [ ] Stop/Cancel first-click focus, no activation on completion, display/Dock/fullscreen placement.
- [ ] Long transcript/settings scrolling, resizing, VoiceOver, contrast and dark appearance.
- [ ] Native editor, terminal, browser, secure-field and changed-selection/focus matrix.
- [ ] No wrong-target insertion, duplicate delivery, submission or post-cancel input.
- [ ] Quit/timeout/forced worker termination with real inference and owned-file cleanup.
- [ ] Offline/content-egress observation and source-build reproducibility/provenance review.

Local baseline requires **zero account logins/MFA** and reuses the existing engine
cache. Rust is a separate app: it requires its own initial microphone grant and
Accessibility settings flow if insertion is enabled. Ad-hoc rebuilds may require
renewed macOS consent. Do not run Swift and Rust with the same registered shortcut.
