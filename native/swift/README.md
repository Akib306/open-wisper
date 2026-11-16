# Open Wisper Swift for macOS

Offline English dictation in a native macOS menu-bar app. Start and stop recording with a keyboard shortcut; transcription runs locally and follows the text field and selection captured at Stop. Review and Copy are available when insertion needs your attention.

**Release candidate 1.0.0-rc.2 (bundle 1.0.0, build 2).** See the [release record](../../docs/releases/swift-v1.0.0.md) for the final Swift scope, code-review findings, verification and pending live checks, the [changelog](CHANGELOG.md) for user-facing changes, and the [Rust handoff](../../docs/rust-handoff.md) for the next track.

## Download and install

**[Download the ready-to-run app for Apple Silicon](https://github.com/Akib306/open-wisper/releases/download/swift-v1.0.0-rc.2/Open-Wisper-Swift-1.0.0-rc.2-macos-arm64.zip)** (macOS 14+, approximately 610 MB). Unzip it, drag **Open Wisper Swift.app** to **Applications**, and open it there. The speech engine and all three models are included; no development tools or provisioning commands are required.

This is an ad-hoc-signed, unnotarized preview. If macOS blocks the first launch and you trust the downloaded build, use **System Settings → Privacy & Security → Open Anyway**, then confirm Open. [Apple's instructions](https://support.apple.com/en-us/102445) explain the prompt. Grant microphone access on first recording and Accessibility for cursor insertion as described below. An Intel build is not available.

Choose the app ZIP under [release assets](https://github.com/Akib306/open-wisper/releases/tag/swift-v1.0.0-rc.2), rather than GitHub's source-code archives. Updates use the same download-and-drag process after quitting the previous app. Keep a copy of the previous bundle if you need to roll back; macOS may require renewed consent for changed ad-hoc code.

## Use

1. Choose **Enable cursor insertion…** in Open Wisper and enable this app in **System Settings → Privacy & Security → Accessibility**. This is needed once for inserting into other apps; macOS may require renewed access after re-signing. The app cannot grant itself access.
2. Place the cursor in a text field. Press **Command–Shift–Space** to start recording, then press again to stop. A nonactivating pill stays visible at the bottom of the display, above the Dock. The shortcut can be changed in Settings; an occupied combination leaves the previous registration intact. Allow microphone access on the first recording.
3. After local transcription, words are sent to the field and selection captured at Stop. The app does not pop up or take focus. Web editors use one targeted Paste, even if they report writable `AXSelectedText`; native fields use direct selected-text replacement where supported, otherwise Paste. It checks process identity, element, selection, editability, and security before writing. Keep the destination unchanged while transcription finishes.
4. If insertion cannot proceed, the quiet indicator offers **Review** and **Copy**. Only choosing Review opens the app. You can turn off **Insert at cursor when dictation stops** in Settings. Closing/dismissing review or starting another session clears the in-memory transcript. Closing the window during recording leaves the visible indicator and menu controls running.

At Start, the app asks the foreground editor to expose its accessibility tree using Electron’s documented `AXManualAccessibility` handshake; it repeats preparation if you switch apps while recording. This does not capture a destination until Stop. Focus resolution verifies the process owner, and the secure-field check supports deep editor layouts within a 128-parent and 250 ms traversal budget. Missing ancestry and secure fields still block insertion.

Focus resolution follows explicit focused-child links through containers within the same process, bounded to 16 elements and 250 ms. A writable native text view may omit the optional `AXEnabled` attribute; that definitive unsupported response is accepted only with positive editability evidence. Explicit disabled states, malformed values, and other accessibility errors still block insertion.

Paste temporarily puts the transcript on the clipboard. Up to 8 MiB, 16 items, and 32 types per item are preserved in memory; declared promised-file data is rejected. Text is supplied when requested, with a two-second request timeout and a 500 ms restoration grace period after a request. Ownership-marker reads do not consume text. The previous contents are restored only while the clipboard change count and the app’s unique marker still match. A newer user/app copy is left alone. A clipboard manager can also request text, so neither a data request nor the grace period proves insertion; external editors and clipboard managers still need compatibility testing. No request observed means an ambiguous outcome, not permission to retry automatically.

The app never activates another app to deliver text, writes a whole document value, presses Return, submits a form, or retries an ambiguous insertion. Known terminals and secure fields are blocked. AX success or emitted Paste is an **insertion request**, not verified final text. A focus race across processes cannot be eliminated by these checks; live editor conformance remains a release gate.

**Cancel** immediately revokes delivery, stops capture, and terminates the worker. An unresponsive worker is killed after two seconds. Quit waits for normal cleanup. Cancel and Quit do not wait for an unanswered microphone permission request; any late response cannot start the cancelled session, though macOS controls the dialog itself. Recording automatically stops at the selected limit (five minutes maximum); the hard audio-frame cap also stops hardware if the UI timer is delayed. Device/format changes and sleep interrupt capture instead of silently resuming it.

Use **Command-comma** for Settings and **Command-Q** to quit. The Edit menu supports Copy and Select All in selectable text.

Use **Command-1**, **Command-2**, and **Command-3** for Ready, Review, and Settings. **Command-Return** starts/stops from the window or opens engine setup when needed; **Command-Shift-C** copies in Review. Copy and Clear remain visible with long transcripts. Closing the window or starting a new recording clears the current transcript; no history is saved.

### Peak transcription memory

The Ready and Review screens keep **Transcription peak** visible in a footer, including at the minimum window size, with a placeholder before the first run. This is the engine worker's maximum resident set size (RSS), collected with macOS `wait4` / `ru_maxrss` when reaping the process, including workers too brief to appear in Activity Monitor. It includes model and engine working memory, excludes the GUI and system services, and is not Activity Monitor's physical-footprint metric or a combined app-tree peak. macOS reports this value in bytes; the UI formats it using memory units.

The reading survives dismissing a transcript and starting or cancelling another recording. It is replaced when another engine run returns successfully; unavailable measurements are explicitly labeled. Failed/cancelled engine runs leave the previous reading intact. The value stays in memory only and resets when the app quits. The info button explains its scope.

The current design calls for a solid petrol pill and solid Pebble surfaces, including the transcript, in both appearances.

Account login/MFA prompts: **zero**. macOS may request Touch ID or a password when changing Accessibility settings; this is not automatically repeated. A fresh packaged app needs microphone access and one Accessibility setup flow for cursor insertion; review-only mode needs no Accessibility access. The Carbon shortcut does not request Input Monitoring. No AppleScript Automation, Screen Recording, cloud account, API key, or subscription is required. The development bundle uses ad-hoc signing: its designated requirement is tied to the executable hash, so rebuilding can require renewed Accessibility approval. A stable bundle ID alone does not guarantee permission continuity; validate it after an update.

## Build from source (developers)

The app is implemented in Swift 6, AppKit, and SwiftUI, with AVAudioEngine capture and a C11 atomic ring for realtime buffer handoff. Source builds require macOS 14 or later, an Apple Swift 6 toolchain (validated here with Swift 6.2 on Apple Silicon), and Python 3 for provisioning/packaging. Building the engine from scratch also requires CMake. Run from the repository root:

```sh
python3 tools/engine/provision.py
bash native/swift/scripts/build-app.sh
open 'native/swift/dist/Open Wisper Swift.app'
```

The first command reuses and verifies the existing engine profile. If artifacts are absent, use `python3 tools/engine/provision.py --build` instead. See [engine provisioning](../../tools/engine/README.md) for offline imports and provenance.

The build script downloads and verifies tiny.en-q5_1, base.en, and small.en at a pinned upstream revision, caching them under `tools/engine/runtime/models` (override with `OPEN_WISPER_MODEL_CACHE`). It bundles all three models and the verified engine with relative manifests: approximately 668 MB of model data. Packaging requires network access on a cache miss; the installed app needs no network, login, or model download. The Settings picker defaults to base.en and persists the choice. Existing custom profiles remain supported. Set `OPEN_WISPER_PROFILE=/absolute/path/manifest.json` to provide the engine profile used for packaging. Missing or hash-mismatched assets fail verification rather than silently selecting another model.

The build script refuses to replace a running app, because rebuilding does not update its loaded code or in-memory settings. Quit the app after keeping any transcript you need before rebuilding its bundle. The default development output is `native/swift/dist/Open Wisper Swift.app`. To update the installed app, quit it and run `OPEN_WISPER_APP_DIR="/Applications/Open Wisper Swift.app" bash native/swift/scripts/build-app.sh`, then open that installed bundle.

The local bundle is ad-hoc signed with the stable ID `dev.akib.openwisper.swift`. It is not notarized. To use an existing signing identity, set `SIGNING_IDENTITY` when building. Rebuilding an ad-hoc-signed app may require renewed macOS permission setup; keep one packaged copy at a stable location while testing.

Packaging assembles and validates a fresh staging bundle before replacing the stopped app, signs the nested worker before recording its packaged hash, and rejects engines with non-system dynamic dependencies. Failed downloads or signing leave the previous installation untouched. For durable signing and the proposed Sparkle OTA workflow, see [macOS updates and permissions](../../docs/macos-updates.md). No automatic updater is enabled yet.

The bundle includes engine/model licenses at `Contents/Resources/THIRD-PARTY-NOTICES.txt`, copied from [the source notice file](Resources/THIRD-PARTY-NOTICES.txt) before signing. These third-party notices do not select a license for the project's own source code.

Current development choice: keep ad-hoc signing without Apple Developer account setup. Revisit Sparkle only after the Rust app is implemented and the UI is polished; permission renewal may remain necessary in the meantime.

Only one GUI instance runs per user, including when launching a second bundle copy. Opening another copy returns to the existing app; an active recording keeps its nonactivating indicator. CLI checks and transcription commands can still run independently. Moving the bundle preserves settings and resolves its bundled engine profile at the new location.

## Development and verification

```sh
swift build --package-path native/swift
swift test --package-path native/swift --no-parallel
native/swift/.build/debug/OpenWisper --check-profile --profile tools/engine/runtime/manifest.json
native/swift/.build/debug/OpenWisper --transcribe-wav /path/audio.wav --profile tools/engine/runtime/manifest.json
```

Check cursor-insertion readiness without recording, posting events, reading document text, or changing the clipboard:

```sh
'/Applications/Open Wisper Swift.app/Contents/MacOS/OpenWisper' --check-delivery
```

Copy fallback can mean Accessibility is unavailable, or that a safe destination could not be established or revalidated despite permission. Check the running app's report and its reason before changing settings. An ad-hoc rebuild can change code identity and require a renewed grant; repeated toggle/restart loops have previously failed and are not a diagnosis. The November 14 running-app check found insertion enabled and Accessibility allowed, with no eligible focused field at that moment. The reported intermittent failure remains unconfirmed; readiness does not prove successful live insertion.

The report includes `automaticInsertion`, `accessibilityGranted`, `eligibleFocusedField`, a failure `reason`, and content-free role/ancestry metadata. When the GUI is running, `source` is `running Swift app`: the command queries that process without activating it or changing the session’s saved target. If the GUI does not reply within two seconds, the report explicitly identifies the standalone CLI, whose permissions macOS may attribute to the launching terminal. A false Accessibility result from the running app requires enabling **Open Wisper Swift.app** in System Settings → Privacy & Security → Accessibility. A false eligible-field result can simply mean Settings or another noneditable surface is focused. This command never prompts, records, reads document text, or pastes.

The CLI accepts mono 16 kHz signed 16-bit PCM RIFF WAV, including extra metadata chunks, up to five minutes. It prints only the requested transcript; errors contain no worker stdout/stderr. CLI paths never request microphone or Accessibility permission. Use the packaged app for live capture, so macOS grants permissions to the application identity.

UI render checks without microphone access:

```sh
native/swift/.build/debug/OpenWisper --render-preview /tmp/open-wisper.png
native/swift/.build/debug/OpenWisper --render-preview /tmp/open-wisper-settings.png --preview-settings
native/swift/.build/debug/OpenWisper --render-preview /tmp/open-wisper-memory.png --preview-memory
native/swift/.build/debug/OpenWisper --render-indicator /tmp/open-wisper-pill.png --preview-state recording
native/swift/.build/debug/OpenWisper --render-indicator /tmp/open-wisper-processing.png --preview-state processing
native/swift/.build/debug/OpenWisper --preview-ui --preview-state recording
```

`--preview-memory` supplies an illustrative 128 MB reading for layout checks only. Add `--preview-light` or `--preview-compact` for light appearance or the 340 × 420 pt minimum content size. Pebble defaults to 360 × 480 pt; settings scroll rather than removing controls. The transcription peak and its pre-run placeholder are visible in the main window. Offscreen bitmap renders check layout, not live focus or display safe areas.

`--preview-state` accepts `idle`, `recording`, `processing`, `review`, `failure`, or `cancelled`. `--render-indicator` previews the bottom pill. `--preview-ui` exercises the real AppKit indicator/window lifecycle with fake capture, permissions, transcription, and delivery: no audio capture, inference, clipboard writes, insertion, global-hotkey registration, or settings-file writes. Stop finishes a sample transcript after two seconds; Cancel discards it. Preview settings start from defaults, not personal settings. Do not use its OS permission setup controls for validation; permission and actual insertion checks belong to the packaged production app.

Additional synthetic states are `long-review`, `copied`, and `copy-failed`. Copy success/failure in preview never changes the clipboard. `--preview-engine ready|missing|checking|failed` simulates engine availability; `--preview-wide` renders 900 × 720 pt. `--preview-ui --preview-state idle` explicitly opens the test window. The [November 15 UX audit](../../docs/research/ui-audit-2026-11-15.md) records scores, native screenshots and validation limits.

### Bottom pill and Pebble

Swift implements a single solid petrol Capsule for all visible states, centered and bounded in the usable area at `visibleFrame.minY + 28` pt, above the Dock, without notch integration. Idle launch leaves both surfaces hidden. Placement follows the display selected at activation and responds to display configuration changes. The legacy `--preview-detached` flag is accepted as a no-op. Source changes alone do not replace the installed app.

Click the indicator's status to open the independent Pebble window; Review selects transcript review and setup opens Settings. Stop/Cancel accept the first click without activating the app. Closing or minimizing Pebble does not stop capture. Successful insertion briefly confirms on the indicator (an unverified Paste is labeled “Insertion requested,” not “Inserted”); recovery remains available through explicit Review/Copy. No completion opens a closed window. Both appearances use solid, high-legibility surfaces without simulated audio or spatial animation. Building source alone does not replace the installed application or renew its ad-hoc Accessibility approval; the latest installation and permission checkpoint is recorded in [Swift verification status](../../docs/swift-status.md).

Copy and Dismiss update the pill even when used in Pebble. Successful Copy hides the recovery pill; failed Copy leaves recovery available. Closing an idle review window clears its in-memory transcript. Starting another recording cancels any old completion-dismissal timer.

Tests exercise lifecycle races, cancellation at every stage, stale completions, one-time delivery, permission denial and cancellation before an unanswered request completes, settings/shortcut rollback, WAV framing and native conversion, anti-alias rejection, bounded ring behavior, engine integrity, hostile worker output, timeout/escalation, process-group cleanup, and safe stale-file recovery. See [verification status](../../docs/swift-status.md) for actual results and remaining manual checks.

## Storage and recovery

Settings: `~/Library/Application Support/dev.akib.openwisper.swift/settings.json`, versioned, validated, atomically replaced, and mode `0600`. Version 1 preview settings adopt cursor insertion in memory while keeping the selected shortcut, engine, and limits; the next save writes version 2. A version 2 explicit opt-out is preserved. Unsupported/corrupt settings are preserved and must be moved aside explicitly before restarting. No transcript/audio history is persisted there.

Inference uses private `0700` directories named `session-<UUID>` within the current user's OS temporary directory, under `open-wisper-swift-sessions-v1-<uid>`. Only `.owner` and `audio.wav` are expected; files are `0600`. Normal completion, failure, cancellation, and timeout clean them up. Startup recovery removes recognized, unlocked entries older than 24 hours without following symlinks. Unknown contents are left untouched. If recovery reports a problem, inspect only that app-owned directory manually; do not delete arbitrary temporary folders. Deletion is not secure erasure, and abrupt OS/process termination can leave audio until recovery.

## Scope

Implemented: English local dictation, menu/status UI, registered configurable toggle shortcut, recording indicator, native audio conversion, cancellation/limits, supervised CLI, profile validation, cursor insertion with direct AX/guarded Paste, quiet review/Copy fallback, atomic settings, and content-free monotonic session timings.

Not implemented: hold/Fn-only shortcuts, device picker, resident/streaming inference, VAD, history, snippets, rewrite, launch-at-login, multilingual profiles, updater, or external comparative memory benchmarks. These remain separate planned work. This is the Swift v1 feature baseline; it does not claim Wispr parity or completion of the entire native release suite. The release record retains the outstanding live acceptance gates.
