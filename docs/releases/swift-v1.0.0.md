# Open Wisper Swift 1.0.0

Status: **downloadable release candidate; final live acceptance is pending**. [GitHub prerelease `swift-v1.0.0-rc.2`](https://github.com/Akib306/open-wisper/releases/tag/swift-v1.0.0-rc.2) distributes the ready-to-run Apple Silicon app. Version 1 closes the Swift feature baseline before work on the independent Rust app. The bundle identifies itself as **1.0.0, build 2**, with bundle ID `dev.akib.openwisper.swift`; this prerelease does not claim every acceptance scenario has passed.

## Current candidate — November 15, 2026

**[Download Open Wisper Swift 1.0.0-rc.2](https://github.com/Akib306/open-wisper/releases/download/swift-v1.0.0-rc.2/Open-Wisper-Swift-1.0.0-rc.2-macos-arm64.zip)** for Apple Silicon, macOS 14+. Extract the ZIP, quit the previous app after keeping any wanted transcript, and drag **Open Wisper Swift.app** into Applications. The engine and all three English models are included. The ad-hoc-signed app is not notarized; follow the [first-launch instructions](../../README.md#download-for-macos) if macOS blocks it. Updates can require renewed Accessibility consent.

This candidate includes the [November 15 UI simplification](../research/ui-audit-2026-11-15.md), visible transcription memory, Copy confirmation/retry, keyboard navigation, and native/nested focused-field delivery fixes. **117 Swift tests across 22 suites passed** on this source, including native keyboard journeys and a mutation-checked Copy dismissal regression. This publication reused the verified installed bundle without rebuilding, re-signing, relaunching, or changing permissions.

| Artifact | Identity |
| --- | --- |
| Release tag / matching source | [`swift-v1.0.0-rc.2`](https://github.com/Akib306/open-wisper/tree/swift-v1.0.0-rc.2) |
| App archive | `Open-Wisper-Swift-1.0.0-rc.2-macos-arm64.zip` — 610,194,316 bytes |
| Archive SHA-256 | `9c55d245d42ba015061463727e9db287ee19462b9194b2277f1a16fe688e6a0b` |
| App executable SHA-256 | `a80305cf0cfa08b000326923673ac63c01348c419d0603d9d24083a44ca95c98` |
| Bundle metadata | 1.0.0 / build 2, retained to distribute the exact installed binary; the candidate tag distinguishes this update. |
| Companion assets | `SHA256SUMS.txt`, `BUILD-INFO.json` |

Fresh extraction preserved executable permissions, bundle metadata, third-party notices, all three relocated engine/model profile checks, and strict recursive signature verification. The running installed app also confirmed Accessibility allowed and automatic insertion enabled after explicit user approval; this readiness check does not establish end-to-end dictation. The existing live acceptance matrix below remains open, so this stays a **prerelease**. The first candidate's tag and asset bytes remain unchanged.

## First candidate — November 14, 2026

[Download the app ZIP](https://github.com/Akib306/open-wisper/releases/download/swift-v1.0.0-rc.1/Open-Wisper-Swift-1.0.0-rc.1-macos-arm64.zip), extract it, drag **Open Wisper Swift.app** into **Applications**, and open it there. The download includes the worker and all three models. End users need no compiler, package manager, provisioning command, or separate model download. See the [installation and first-launch instructions](../../README.md#download-for-macos) for the ad-hoc-signing prompt and macOS permissions.

| Artifact | Identity |
| --- | --- |
| Release tag / source | `swift-v1.0.0-rc.1` / `3482c4d` |
| Platform | Apple Silicon (`arm64`), macOS 14+ declared; validated on the recorded newer Apple Silicon host. No Intel asset. |
| App archive | `Open-Wisper-Swift-1.0.0-rc.1-macos-arm64.zip` — 610,183,437 bytes |
| Archive SHA-256 | `c2cee2b2e94da91ffdee9cb1a009a02e8cb8421e2125ca9379e2939d5b486fea` |
| Checksum asset | `SHA256SUMS.txt` |

The archive was created with macOS `ditto --keepParent` from the already validated bundle, without rebuilding or re-signing. A fresh extraction retained executable permissions, the recorded executable hash, version/build, notices, all three relocated profile checks, and strict recursive signature verification. The ZIP and checksum are GitHub release assets, not files in git. GitHub's automatically generated source archives are for developers.

## What version 1 includes

- A macOS 14+ menu-bar app, initially validated on Apple Silicon, with a configurable toggle shortcut (default Command–Shift–Space).
- Explicit microphone capture, a nonactivating solid petrol bottom pill, and a separate Pebble window for Settings and transcript review. Stop and Cancel work without activating the window; completion does not take focus.
- Offline English transcription using pinned whisper.cpp v1.8.1, CPU/Apple Accelerate, four threads, and a short-lived worker. Settings selects `tiny.en-q5_1`, `base.en` (default), `small.en`, or an explicitly chosen custom profile. Model quality/performance comparisons remain experimental.
- Cursor insertion enabled by default, with target/selection captured at Stop and revalidated before delivery. Native fields use selected-text replacement where supported; web fields use one guarded Paste. Unsafe or unavailable destinations offer Review/Copy. An insertion request is not a verified edit.
- Cancellation, automatic recording limits (five minutes maximum), worker deadlines and kill escalation, bounded PCM/output buffers, private temporary WAVs, stale-session recovery, versioned atomic settings, and retained engine peak-RSS reporting.

See the [Swift user/developer guide](../../native/swift/README.md), [behavior contract](../native-contract.md), [bottom-pill decision](../decisions/0002-bottom-pill.md), and [changelog](../../native/swift/CHANGELOG.md) for exact behavior.

## Review scope and findings

The November 14, 2026 review started at commit `332e1df` and covers every source file under `native/swift/Sources`, the Swift test suites, `Package.swift`, the bundle resources/build script, and the shared engine provisioner/packager. The release preparation changes build on that baseline. Electron was retained as a reference and Rust was not implemented in this pass.

| Area | Reviewed behavior |
| --- | --- |
| WisperCore | Session identity and state, cancellation/stale callbacks, delivery authorization, settings migration/rollback, instance lock, RIFF parsing, manifest/artifact integrity, process supervision, private workspace ownership and cleanup. |
| CWisperAudio / WisperPlatform | Atomic bounded ring, callback lifetime, native conversion/downmix/clipping, capture teardown/device interruption, permissions, global shortcut, AX focus/security checks, clipboard ownership and restoration. |
| OpenWisper | Menu/window/pill lifecycle, review/Copy/dismiss synchronization, settings and model verification, previews, command-line entry points, content-free readiness diagnostics. |
| Release tooling | Offline model cache and pinned hashes, relocatable profiles, system-only engine dependencies, nested signing order, staged replacement/rollback, version metadata and third-party notices. |

Confirmed fixes:

- **Medium — cancellation at a phase transition:** a synchronous observer could cancel while entering preparation, finalization, or transcription, yet the corresponding operation would still be started afterward. The coordinator now rechecks the session after each transition. Three regressions first observed an unwanted microphone request, capture Stop, and transcriber call, then passed with the guards.
- **Low — stuck engine verification:** clearing a profile during verification could leave `checkingEngine` true. Reset it before the empty-profile return; a regression reproduced the old behavior and passed with the fix.
- **Release packaging — version and notices:** the bundle still declared 0.1.0 and omitted license notices for the engine and model weights. The candidate declares 1.0.0/build 2 and packages `Contents/Resources/THIRD-PARTY-NOTICES.txt` before signing. This does not select a distribution license for Open Wisper's own source.

No other confirmed defect was found in the reviewed scope. Artifact verification is a point-in-time integrity check; subsequent path-based access does not protect against concurrent replacement or establish upstream authenticity. No audit establishes that a program is bug-free. The manual checks and known limitations below remain part of this release record.

## Build and verify (maintainers)

From the repository root, with Xcode/Swift and the previously provisioned engine available:

```sh
swift test --package-path native/swift --no-parallel
python3 -m unittest discover -s tools/engine -p 'test_*.py'
python3 tools/engine/provision.py
bash native/swift/scripts/build-app.sh
codesign --verify --deep --strict 'native/swift/dist/Open Wisper Swift.app'
```

The build script validates all three packaged model profiles and the final signature before replacing its output. It stages at `native/swift/dist`; it does not install over `/Applications` or launch the app. Missing cached models require a one-time public HTTPS download during packaging. Installed dictation needs no network or model download. Source engine/model provenance and hashes are documented in the [engine guide](../../tools/engine/README.md).

Automated results and artifact identity from this pass are recorded in the current entry in [Swift verification status](../swift-status.md). A sandbox compiler-cache failure is an environment failure, not a passing or failing app test; use a test environment with the compiler caches and AppKit/pasteboard services available. Do not disable assertions or relax deadlines to obtain a pass.

To package a verified bundle for a GitHub release, preserve the app bundle with macOS `ditto`. These commands are for maintainers, not installation steps:

```sh
cd native/swift/dist
ditto -c -k --sequesterRsrc --keepParent 'Open Wisper Swift.app' Open-Wisper-Swift-1.0.0-rc.1-macos-arm64.zip
shasum -a 256 Open-Wisper-Swift-1.0.0-rc.1-macos-arm64.zip > SHA256SUMS.txt
```

Before publishing, freshly extract the archive, verify its signature and all three profiles, and compare executable identity with the tested build. Upload the ZIP and checksum as release assets; verify GitHub's uploaded size/digest and the anonymous download. Use a new version/tag for changed bytes rather than replacing an existing release asset.

## Final live acceptance

Use the exact staged bundle in controlled scratch documents and record the build/hash and results. Historical fixtures and a read-only `--check-delivery` report do not replace these checks.

| Pending check | Acceptance |
| --- | --- |
| Microphone and normal dictation | First-use allow/deny, short utterance, automatic limit, and repeat recording behave correctly with visible capture. |
| Real destination compatibility | TextEdit/native field, browser textarea/contenteditable, and an Electron editor each receive one edit at the Stop selection; unchanged focus stays in the destination. |
| Safety and ambiguity | Focus/selection switch, secure field, terminal, app exit, Cancel during inference, and repeated Stop produce no wrong-target insertion, duplicate delivery, or submission. Ambiguous results never retry automatically. |
| Clipboard coexistence | Rich clipboard restoration, newer user copy, and clipboard-manager activity leave newer clipboard data alone and present honest request/review status. |
| Hardware and windows | Device unplug/format change, sleep/wake, external displays, Dock variations, full-screen Spaces, and first-click Stop/Cancel recover explicitly and keep the pill visible/bounded. |
| Accessibility and shortcut | VoiceOver/keyboard navigation, occupied-shortcut rollback, and permission continuity on the packaged build are checked on the actual OS. macOS 14 minimum compatibility and Intel are not established by building on a newer Apple Silicon Mac. |

The previously reported intermittent Copy fallback remains **unconfirmed**. The earlier running-app report showed Accessibility allowed but no eligible field; that was a readiness observation, not an insertion trial or a repair. Preserve target/security guards and use content-free diagnostics with a controlled editor before assigning a cause.

## Privacy, updates, and recovery

No account, API key, subscription, login, or MFA is required: **zero account-authentication prompts**. A fresh app requests microphone access when recording, plus one explicit Accessibility setup flow for insertion. Review-only mode needs no Accessibility access. Carbon shortcuts need no Input Monitoring; basic dictation needs no Screen Recording, Automation, or Speech Recognition permission.

Signing remains ad hoc by the user's decision. A rebuild can change code identity and require renewed OS permission; macOS may ask for Touch ID/password in Privacy settings. Batch installation and verification around one final build rather than repeated rebuild/permission cycles. Do not repeat previously unsuccessful permission toggle/restart loops. No TCC reset, certificate enrollment, or updater setup belongs to this release. [Update/signing decisions](../macos-updates.md) remain in force; Sparkle stays deferred until Rust and UI polish.

Settings live at `~/Library/Application Support/dev.akib.openwisper.swift/settings.json` (schema 2, mode 0600); the app does not persist transcript history. Review is memory-only until Copy. Paste temporarily exposes text to the system clipboard and other applications. Private session WAVs are removed on normal cleanup; crashes can leave recognized files until safe recovery after 24 hours. Deletion is not secure erasure. See the Swift guide for exact bounds and recovery rules.

For an eventual installation, preserve any wanted transcript, quit the existing app, retain its stopped bundle as rollback, and install the already validated candidate at the chosen path. Do not rebuild or re-sign merely to install the same artifact. If rolling back, quit the candidate and restore the saved bundle; preserve settings, including an explicit insertion opt-out. Earlier builds may not understand newer settings: keep the settings backup and never silently overwrite an unreadable file. No installation or permission change is implied by this source-review record.

## Release boundary and Rust

Hold/Fn-only shortcuts, device selection, VAD/streaming/resident inference, multilingual profiles, history, snippets/rewrite, launch-at-login, OTA updates, notarized public distribution, and controlled language/engine benchmarks remain outside Swift v1. The preview is downloadable while the declared live matrix remains pending; it is not a fully accepted stable release. The upstream whisper.cpp public security-advisory API returned no published entries on November 14, 2026; this is a check of that inventory, not a complete vulnerability assessment. A project-wide source distribution license remains unselected; the bundled third-party notices are included.

The first downloadable candidate uses `swift-v1.0.0-rc.1`, targeting the reviewed source at `3482c4d`; the current UI/delivery candidate uses `swift-v1.0.0-rc.2` and its matching source tag. Reserve `swift-v1.0.0` for stable acceptance; do not move the candidate tag or replace its asset bytes silently. Future versions receive a new tag and artifact/checksum. Continue with the [Rust handoff](../rust-handoff.md), carrying the behavior contract and unresolved checks forward.
