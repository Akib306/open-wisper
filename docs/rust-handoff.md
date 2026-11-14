# Rust handoff from Swift v1

Implementation update, November 14, 2026: the independent Rust application now lives in [`native/rust`](../native/rust/README.md). See [Rust verification status](rust-status.md) for automated results, unsupported browser Paste, manual crash-audio cleanup, and remaining live gates. This handoff remains the baseline specification, not a claim that every requirement has passed.

Swift v1 is the feature baseline described in the [release record](releases/swift-v1.0.0.md). Rust is the next independent application, as agreed in the [native plan](native-plan.md); this document captures what must carry forward. It does not claim Swift's pending live acceptance checks have passed.

## Keep these decisions

- Implement Rust application coordination and platform adapters independently. Reuse the specifications, original fixtures, engine artifacts/provenance, and benchmark methodology. Do not turn the Swift app into a wrapper around a shared Rust core or introduce a WebView by default.
- Preserve offline English dictation, explicit capture, a configurable registered toggle shortcut, automatic insertion with a saved opt-out, and explicit Review/Copy recovery.
- Use the [bottom pill and separate Pebble](decisions/0002-bottom-pill.md) design: centered at `visibleFrame.minY + 28`, bounded to the work area, no notch integration, no automatic activation on completion, first-click Stop/Cancel. Idle launch opens neither surface.
- Keep independent Swift/Rust bundle IDs, settings, single-instance ownership, and macOS grants. Two app variants mean two initial permission setups; no shared-identity trick should bypass OS consent. Do not run both with the same registered shortcut.
- Ad-hoc signing and deferred Sparkle remain the user's choice. No Apple Developer enrollment, certificate/keychain changes, or updater work is a prerequisite for Rust.

## Source map for behavior reference

| Swift source | Rust responsibility |
| --- | --- |
| `WisperCore/SessionCoordinator.swift` | Serialized commands/events, session IDs, one worker, cancellation and stale-result rejection, one consumed delivery authorization, timing/outcome reporting. |
| `CWisperAudio/AudioRing.c`, `WisperPlatform/AVAudioCapture.swift`, `AudioConverter.swift` | Bounded real-time handoff, immutable generation identity, owned hardware teardown, mono 16 kHz PCM16 WAV with anti-aliased conversion and final-frame flush. |
| `WisperCore/EngineManifest.swift`, `WhisperTranscriber.swift`, `ProcessSupervisor.swift`, `SessionWorkspace.swift` | Strict manifest/host/hash checks, direct argv, explicit environment, fair bounded pipe draining, worker process group, deadlines/escalation/reap, private owned audio cleanup and crash recovery. |
| `WisperPlatform/AccessibilityDelivery.swift`, `FocusedElementResolver.swift`, `AncestrySecurityResolver.swift`, `ClipboardPaster.swift`, `WisperCore/DeliveryPolicy.swift` | Metadata-only target snapshot at Stop, secure ancestry/focus/process/selection revalidation, native selected-text replacement, guarded web Paste, bounded ownership-aware clipboard restoration, no ambiguous retry. |
| `WisperPlatform/PermissionsService.swift`, `GlobalHotkey.swift`, `WisperCore/SettingsStore.swift`, `ApplicationInstanceLock.swift` | Feature-scoped consent and cancellable waiters, transactional shortcut replacement, validated atomic settings and migration, one GUI process per user. |
| `OpenWisper/AppDelegate.swift`, `AppModel.swift`, `Views.swift`, `UIPreview.swift`, `DeliveryDiagnostics.swift` | Nonactivating indicator and independent window, synchronized review/Copy/dismiss, cancellable model verification, permission-free fixtures, content-free running-app diagnostics. |
| `native/swift/Tests` and `tools/engine/test_package_models.py` | Regression inventory. Port observable invariants into Rust-owned tests rather than matching incidental scheduling or treating fixtures as live editor proof. |

Paths above are relative to `native/swift/Sources` unless otherwise noted. Read the [contract](native-contract.md) before using an implementation detail as a requirement.

## Engine and measurement parity

Use the exact pinned whisper.cpp v1.8.1 source commit, CPU/Apple Accelerate backend, four threads, decode argv, English language, and short-lived-worker policy from the [engine manifest](../tools/engine/README.md). Swift defaults to `base.en`; `tiny.en-q5_1` and `small.en` remain explicit selectable alternatives. The bootstrap provisioner uses `small.en` to supply engine metadata; it does not define the app's default model.

For any Swift/Rust comparison, choose the **same model and exact engine bytes** and retain both manifests, hashes, toolchain/OS/hardware, input fixture, settings, and warm/cold policy. Nested signing can change worker bytes, so compare the recorded packaged digests rather than a source version label. Include bundled third-party notices in both applications.

The current engine-memory reading is the short-lived worker's `wait4` maximum RSS, not Activity Monitor footprint, combined GUI/worker memory, or idle usage. Keep these labels honest. Measure idle/capture/inference/resource behavior separately with original or consented fixtures; no language performance winner has been established. Do not substitute a resident model, different engine, or different decoding policy and call it a Rust-vs-Swift result.

## First implementation slices

1. Validate Rust/AppKit feasibility on the selected macOS/toolchain: status item, separate window and nonactivating panel, registered shortcut, AVAudioEngine/converter bindings, and AX/pasteboard capabilities. Pin dependencies only after this spike; isolate unsafe FFI with ownership, thread, callback, and cancellation contracts.
2. Implement a Rust-owned coordinator and deterministic fake-adapter tests for Start/Stop/Cancel, repeated commands, stale completions, quit and one-time delivery. Keep framework objects on their valid thread; transfer PCM/events through bounded channels.
3. Connect the shared pinned engine through a supervised worker and private workspace, then validate normal output, malformed audio/profile, missing/tampered assets, nonzero exit, flood, hang, cancellation, process-group teardown, and cleanup.
4. Add real capture/conversion with bounded buffers and hardware interruption handling; verify fixtures and frame limits before live microphone acceptance.
5. Add fail-closed delivery and quiet review/Copy fallback, validated settings/shortcut rollback and single-instance behavior, then exercise the declared scratch-editor/clipboard/permission matrix on a packaged build.
6. Package relocatable engine/models, licenses and version metadata. Run the shared acceptance scenarios and controlled resource comparison before deciding which implementation to prefer or attempting any user migration.

These are ordered slices, not a promise that untested APIs or proposed crates already work. The original [R1–R4 and shared tasks](native-plan.md) retain their detailed acceptance requirements.

## Unresolved evidence to carry forward

The [Swift release record](releases/swift-v1.0.0.md#final-live-acceptance) lists the remaining microphone/device, live cross-app delivery, clipboard-manager, display/full-screen, VoiceOver, shortcut-conflict, minimum-OS and Intel checks. The user's intermittent Copy fallback has not been reproduced; a ready/granted diagnostic is not successful insertion. Do not relax security/focus checks or claim that a Rust rewrite fixes it without a controlled reproduction.

Zero wrong-target insertions, duplicates, and unintended submissions in the declared suite remain release gates for both tracks. Known terminals and secure/unknown contexts must fail closed. Snapshot at Stop, never silently target the current app after inference, never write a whole document value, never synthesize Return, and never retry an ambiguous delivery.

Expected account authentication across a local build/use sequence is **zero**. Reuse caches and final artifacts; explain unavoidable macOS consent when installing a separately identified app or changing ad-hoc code identity. Do not ask users to repeat login/MFA, redundant build commands, or previously unsuccessful permission repairs.
