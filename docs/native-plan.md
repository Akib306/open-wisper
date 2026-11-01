# Independent Rust and Swift implementation plan

Status: **Swift development baseline implemented; Rust remains planned**. Read the [investigation](research/wispr-flow.md) for observations and [v1 contract](native-contract.md) for the target behavior. [Swift verification status](swift-status.md) distinguishes implemented features, completed checks, and open release gates. The later experiments and optional capabilities below remain plans.

## Decision

Build **two independently shippable macOS applications**, not one Rust core with a Swift wrapper. Share specifications, original fixtures, engine provenance, and benchmark methodology. Initially invoke the same pinned `whisper-cli` executable and model from both applications, retaining Electron as a third baseline.

Why this split:

- It answers whether Rust or Swift is the better implementation for this project, rather than measuring two frontends around one language's core.
- The installed product itself includes a native helper alongside Electron; native integration and delivery reliability matter more than copying its UI stack (F01–F03).
- Equal engine/backend/residency policies separate application overhead from inference differences.
- It preserves a later hybrid option without requiring FFI, code generation, or a Rust toolchain in the Swift baseline.

Do not claim Rust or Swift will be faster, smaller, or more reliable before measurement. They both still depend on OS frameworks and a C/C++ inference engine.

## Product scope and priorities

| Priority | Capability | Relation to investigation |
| --- | --- | --- |
| P0 | Shortcut → visible capture → local ASR → cursor insertion | Core workflow clarified by the user on October 31; review/Copy is a quiet fallback. Local inference is intentionally different from observed remote-capable paths. |
| P0 | Guarded insertion, cancellation, permission recovery | Native integration boundary F02/F03 and guarded initialization F06. |
| P0 | Reproducible manifests and comparable resource measurements | Existing MVP provides a baseline, not native results. |
| P1 | Hold-to-talk, device recovery, vocabulary, deterministic snippets | Candidate feature surfaces F09; independently specified behavior. |
| P1 | Optional local rewrite with raw-result fallback and per-app style rules | Separate ASR/formatting stages suggested by F07/F08; no recovered proprietary prompts. |
| P1 | Opt-in history, export, retention controls | History schema surface F07, with deliberately stricter defaults. |
| P2 | Resident model, streaming hypotheses, VAD-assisted stop, multilingual profiles | New optimization/product experiments, not asserted Wispr parity. |
| Deferred | Meeting recorder, notes, calendar, teams, billing, BLE rings, computer-use agents, sync | Adjacent packaged surfaces/dependencies; unnecessary for dictation MVP. |

Start rewriting only after reliable raw dictation. Deterministic snippets need explicit triggers and previews; broad substring replacement can damage names, punctuation, or code. A rewrite timeout or uncertain result must retain raw text and never silently change or drop speech.

## Common architecture, separate code

```text
Hotkey / menu action
        ↓
Serialized session coordinator ─────→ nonactivating indicator
        ↓
Native capture → bounded PCM → conversion → supervised local ASR
        ↓
Raw transcript → optional transform → result review
        ↓
Target validation → permitted insertion OR explicit Copy

Side services: permissions, atomic settings, content-free metrics
```

This is a **proposed architecture**, not Wispr's recovered call graph. Both tracks implement the same ports and invariants from the v1 contract. Capture and workers outlive settings views but remain owned by the application coordinator.

### Rust track

| Component | Initial approach |
| --- | --- |
| Application shell | Native AppKit status item, menus, result/settings windows, nonactivating panel through `objc2`/`objc2-app-kit`; no WebView/Tauri in the native baseline. |
| Capture | `objc2-avf-audio` adapter for AVAudioEngine and native conversion; validate required binding coverage in R1. CPAL is a fallback experiment, not a simultaneous baseline dependency. |
| Coordination | Single serialized coordinator; plain Rust state/events and bounded channels. Keep AppKit on the main thread and avoid moving non-Send framework objects between threads. |
| Shortcuts | Registered key combinations using a small adapter; `global-hotkey` is a candidate, with its macOS manager/event loop on the main thread. Fn-only/event taps are separate feasibility work. |
| Delivery | Audited platform module over Accessibility, Core Graphics, and pasteboard APIs; opaque target handles, not broad UI-text scraping. |
| Worker | Rust process supervisor with direct argv, pipe draining/output limits, deadlines, cancellation, and explicit exit handling. |
| Persistence | Validated versioned settings with atomic replacement; optional SQLite history later, not a prerequisite. |

Concentrate unsafe Objective-C/FFI code in a small platform layer with documented ownership, callback lifetime, thread, and cancellation contracts. Pin crate versions after the feasibility spike, not arbitrary current-version guesses. The framework docs explicitly identify AVAudioEngine as not Send/Sync; channel PCM data rather than the engine itself.

**Rust means Rust application logic plus macOS bindings**, not portable macOS behavior for free. Windows/Linux support requires new capture, permissions, hotkey, and delivery adapters plus platform conformance suites. Treat that as an option, not a promised outcome of v1.

### Swift track

| Component | Initial approach |
| --- | --- |
| Application shell | AppKit lifecycle/status item/nonactivating panel; SwiftUI or AppKit settings/result views. Do not let view lifetimes own the engine. |
| Capture | AVAudioEngine input capture and AVAudioConverter; bounded buffers, conversion off the capture callback/UI thread. |
| Coordination | Swift actor or dedicated serial coordinator, with explicit async commands and session-tagged results; UI mutations on MainActor. |
| Shortcuts | Small registered-combination adapter; verify actual key registration, conflicts, and rollback. Only investigate CGEvent taps if required for later hold/Fn behavior. |
| Delivery | Independently authored AXUIElement/Core Graphics/NSPasteboard adapter with the same fail-closed contract as Rust. |
| Worker | Implemented with POSIX spawn from Swift so a process group is established atomically; bounded pipe reads, timeout/cancel state, termination escalation, and final exit handling. |
| Persistence | Validated atomic settings; optional SQLite-compatible history later. No mandatory Rust runtime/library. |

Swift has the simpler proposed macOS integration route; Rust offers a route toward reusable non-UI logic across platforms. These are design trade-offs, not measured development-effort or performance findings.

### Engine evolution

1. **CLI baseline:** same exact executable/model/arguments and short-lived process policy in Electron, Rust, and Swift. Low idle model residency, explicit supervision, temporary-file costs measured.
2. **Resident-worker experiment:** same separately supervised worker protocol for both native tracks, comparing warm latency against persistent memory. No unauthenticated listening TCP server; prefer inherited pipes/local handles.
3. **Direct C API experiment:** Swift C interop and Rust FFI against the same pinned engine if measurements justify it. Specify allocation ownership, serialized model access, callback lifetimes, cancellation limits, and shutdown. Do not make an in-process unsafe model call merely to claim “pure native.”
4. **Alternative engine experiment:** evaluate independently licensed local engines/Apple-specific options only in a separate quality/performance profile. They cannot establish Rust-vs-Swift shell superiority when model/backend differs.

## Proposed repository layout

Create this only during implementation; do not move or rewrite `mvp/` merely to start:

```text
mvp/                         existing Electron baseline
apps/rust/                   independent Cargo workspace/application
apps/swift/                  independent Swift/Xcode application
specs/                       versioned event/error/config schemas
fixtures/audio/              original or redistributable audio + provenance
fixtures/conformance/        commands, expected invariants, failure scripts
tools/engine/                pinned build/model manifest + provisioning
tools/bench/                 external sampler and result normalization
benchmarks/results/          machine-readable runs, environment, summaries
docs/                        research, decisions, contributor instructions
```

Each native track must build/test without compiling the other language. They may consume the same prebuilt engine artifact. Use distinct stable bundle IDs such as `dev.akib.openwisper.rust` and `dev.akib.openwisper.swift`, separate settings paths, and a launch-time warning if the other build owns the requested shortcut. Do not run both microphone pipelines simultaneously by accident.

## Reuse from the current MVP

| Current source | Reuse / required change in native tracks |
| --- | --- |
| `mvp/src/shared.ts` | Vocabulary for commands/settings/results, not the renderer-owned phase model. Expand with session IDs and honest delivery outcomes. |
| `mvp/src/audio.ts`, `mvp/tests/audio.test.cjs` | WAV and chunk-order test ideas. Replace linear interpolation with anti-aliased native conversion and add signal-quality cases. |
| `mvp/src/main.ts` | Short-lived inference and cleanup intent. Add deadlines, cancel/quit supervision, bounded streams, and cleanup protection before the first write. |
| `mvp/src/main.ts` delivery | Do not port AppleScript activation plus timed Command-V. Bundle-ID-only targeting and “pasted” on script completion are inadequate. |
| `mvp/src/main.ts` shortcuts | Preserve last known-good registration on replacement failure; settings rollback alone does not restore a shortcut. |
| `mvp/src/process-tree.ts`, `mvp/native/process-memory.c` | Process-tree/footprint measurement ideas. Disclose mixed RSS/footprint fallbacks and sampler limits; prefer an external benchmark observer. |
| `mvp/scripts/setup-whisper.sh` | Provisioning starting point. Verify existing checkout commit as well as initial clone; record executable/model hashes. |
| `mvp/BENCHMARK.md` | Historical smoke numbers only. The reported 425.1 MB summed idle RSS is not a native result or the same metric as current physical-footprint reporting. |

These are design inputs, not unrelated bug fixes included in this documentation change.

## Sequenced implementation tickets

Advance on acceptance gates rather than speculative calendar estimates. Once shared contract work lands, Rust and Swift tickets at the same stage can proceed independently.

| Ticket | Dependency | Work | Done when |
| --- | --- | --- | --- |
| C0 | None | Freeze v1 contract; create schema fixtures, original audio provenance, dependency/license policy. | Both track owners agree on event invariants and result/error semantics; no proprietary source in fixtures. |
| C1 | C0 | Pin inference commit/build/model; create one idempotent provisioning command and offline-import path. | Existing installations verify hashes; both tracks consume the identical manifest without duplicate downloads. |
| R1 / S1 | C0 | Independently package status app, permission status, registered shortcut, nonactivating indicator, capture start/stop. | Fresh packaged-build test proves permission behavior, indicator focus, denial recovery, and bounded capture. |
| R2 / S2 | C1, R1/S1 | Supervised CLI transcription and review/Copy. | End-to-end local dictation works offline; cancellation, timeout, quit, and file cleanup pass. |
| R3 / S3 | R2/S2 | Target snapshot at Stop, validation, cursor insertion, quiet fallback. | Native field/browser/terminal/focus-race/clipboard suite passes with no ambiguous auto-retry. |
| C2 | R2, S2 | External benchmark runner; release packaging and shared prerecorded corpus. | Raw results include engine hashes, cold/warm labels, all child processes, metric basis, and failure counts. |
| R4 / S4 | R3/S3, C2 | Hardening: device changes, sleep/wake, settings, hotkey rollback, startup recovery, launch-at-login opt-in. | Shared lifecycle suite and packaged permission/update checks pass. |
| C3 | R4, S4 | Compare results and maintenance friction; choose default distribution track. | Decision uses reproducible measurements plus reliability and implementation effort, not language preference alone. |
| R5 / S5 | C3 | Optional vocabulary/snippets/history/local rewrite; resident engine experiments. | Each capability has consent/retention/failure rules and new conformance fixtures; raw-text fallback preserved. |

First concrete coding slice: **a packaged status item + shortcut + nonactivating recording indicator + ten-second local capture in each language**. This retires framework ownership and permission risks before model integration or visual polish.

## Benchmark protocol

Three distinct experiments prevent misleading conclusions:

1. **Engine-only:** identical prerecorded normalized audio, executable/model/arguments/threads/backend; raw WER/CER and engine time independent of capture or rewriting.
2. **Application overhead:** release-packaged Electron/Rust/Swift, same short-lived worker policy. Measure startup, idle before/after first use, hidden-window recording, worker peak, aggregate memory, CPU, package size excluding/including models, and stop-to-review/stop-to-insertion-request latency.
3. **Product quality:** native capture/device handling, formatting, and safe delivery. Live microphone DSP differs from the current Electron constraints, so do not misattribute different input processing to a language or model.

Record hardware/RAM, OS, power state, thermal state, build configuration, engine manifest, sampler version/frequency, and background load. Randomize track order, use at least 20 measured repetitions per performance condition, and report median, p95, dispersion, failures, and raw samples. Do not call a few trials a stable tail-latency estimate.

Separate process-cold, filesystem-cache-warm, and model-resident conditions. “New process” does not mean a cold OS file cache. Do not purge caches or change system settings just to obtain a label.

Use one external observer for all app trees, with a consistent physical-footprint basis where available. If a reading is unavailable or falls back to RSS, report that explicitly rather than mixing labels. A sum of process footprints is an operational aggregate, not a perfect unique-physical-memory measurement. Fast workers can evade sampling: supplement worker exit resource statistics where available and report aggregate peak as sampled. Disclose observer overhead.

Provisional experiment targets, **not performance claims or universal release guarantees**: idle shell under 100 MiB excluding model residency, hotkey-to-indicator p95 under 100 ms, stop-to-review under two seconds for the declared ten-second tiny-model clip, and cancel/quit worker termination within two seconds before escalation. Replace thresholds after hardware-specific baselines; reliability/privacy gates do not weaken to meet a speed target.

## Friction, safety, and release gates

- Local baseline: zero account logins/MFA; one explicit engine/model provisioning flow reused by both builds. No automatic service sign-up or repeated downloads.
- Fresh-install expectations per app: one microphone authorization flow, then one Accessibility settings flow only if insertion is enabled. Two separate apps mean separate grants. Event-tap/Input Monitoring requirements remain a packaged-build spike; do not promise a count of OS dialogs before testing.
- Do not request broad permissions merely because Wispr's plist contains them. Basic dictation needs no meeting/screen/camera/Bluetooth setup.
- Use a stable packaged identity and signing workflow early to reduce TCC reset/reapproval churn. Validate update behavior; no guarantee that ad-hoc builds retain permissions.
- Ship ordinary source builds and local testing before paid signing/distribution setup. Before public binaries, decide signing/notarization, reproducible provenance, model redistribution terms, dependency licenses, update policy, and project license. No license has been selected by this plan.
- Both tracks must independently pass the v1 conformance suite. No wrong-target insertions, accidental submissions, duplicate deliveries, orphan capture, or post-cancel insertion in that suite.
- Offline/privacy tests must show no content egress or content-bearing default logs; permission denial must not create prompt loops. All insertion paths fail closed when target safety is unknown.

## Optional further Wispr research

Further static native tracing requires granting Automation to the app launching REA for Hopper, then reopening the exact helper digest. No reinstall or repeated authentication sequence is proposed. Live dictation/insertion testing should use a dedicated scratch document and synthetic speech, with separate approval for recording/context/network capture. Inspecting real user history or accounts is not necessary to build either application.

Investigate the actual paste strategy, hold/Fn key semantics, streaming/fallback behavior, and permission recovery only if those answers change our requirements. Server model identity and proprietary prompts may remain unknowable; they are not prerequisites for the local implementation.

## Public implementation references

Primary documentation checked during planning; these establish API/dependency candidates, not working integration or versions to pin blindly:

- `objc2-app-kit` framework documentation: https://docs.rs/objc2-app-kit/latest/objc2_app_kit/ — AppKit initialization/ownership constraints.
- `objc2-avf-audio` AVAudioEngine documentation: https://docs.rs/objc2-avf-audio/latest/objc2_avf_audio/struct.AVAudioEngine.html — native engine binding and non-Send/non-Sync constraints.
- `global-hotkey` documentation: https://docs.rs/global-hotkey/latest/global_hotkey/ — macOS main-thread event-loop requirement.
- Upstream `whisper.cpp`: https://github.com/ggml-org/whisper.cpp — CLI, C API, CPU/accelerated profiles, and WAV input requirements.
- Apple AVAudioEngine: https://developer.apple.com/documentation/avfaudio/avaudioengine — API reference endpoint located; detailed page content was not retrievable in this investigation's web reader.
- Apple AXUIElement and NSPasteboard.changeCount: https://developer.apple.com/documentation/applicationservices/axuielement and https://developer.apple.com/documentation/appkit/nspasteboard/changecount — API reference endpoints located; validate detailed contracts against the SDK during platform spikes.
