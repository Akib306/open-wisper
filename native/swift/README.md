# Open Wisper Swift for macOS

A compact native menu-bar app implemented in Swift 6, AppKit, and SwiftUI. It records with AVAudioEngine, converts audio off the realtime callback, invokes a pinned local whisper.cpp worker, and inserts into the text field focused when recording stops. The Swift application has no Electron or Rust dependency. A small C11 atomic ring provides the realtime buffer handoff.

## Build and launch

Requires macOS 14 or later, an Apple Swift 6 toolchain (validated here with Swift 6.2 on Apple Silicon), and Python 3 for provisioning/packaging. Building the engine from scratch also requires CMake. Run from the repository root:

```sh
python3 tools/engine/provision.py
bash native/swift/scripts/build-app.sh
open 'native/swift/dist/Open Wisper Swift.app'
```

The first command reuses the existing MVP engine/model and verifies their identity. If they are absent, use `python3 tools/engine/provision.py --build` instead. See [engine provisioning](../../tools/engine/README.md) for offline imports and provenance.

The build script embeds a small manifest pointing to those existing artifacts, so there is no repeated model selection or download on this Mac. Keep them at their recorded paths. Set `OPEN_WISPER_PROFILE=/absolute/path/manifest.json` to package another supported profile. A bundle built without a profile prompts for one in Settings.

The build script refuses to replace a running app, because rebuilding does not update its loaded code or in-memory settings. Quit the app after keeping any transcript you need before rebuilding its bundle. The default development output is `native/swift/dist/Open Wisper Swift.app`. To update the installed app, quit it and run `OPEN_WISPER_APP_DIR="/Applications/Open Wisper Swift.app" bash native/swift/scripts/build-app.sh`, then open that installed bundle.

The local bundle is ad-hoc signed with the stable ID `dev.akib.openwisper.swift`. It is not notarized. To use an existing signing identity, set `SIGNING_IDENTITY` when building. Rebuilding an ad-hoc-signed app may require renewed macOS permission setup; keep one packaged copy at a stable location while testing.

Only one GUI instance runs per user, including when launching a second bundle copy. Opening another copy returns to the existing app; an active recording keeps its nonactivating indicator. CLI checks and transcription commands can still run independently. Moving the bundle preserves settings and resolves its bundled engine profile at the new location.

## Use

1. Choose **Enable cursor insertion…** in Open Wisper and enable this app in **System Settings → Privacy & Security → Accessibility**. This is needed once for inserting into other apps; macOS may require renewed access after re-signing. The app cannot grant itself access.
2. Place the cursor in a text field. Press **Command–Shift–Space** to start recording, then press again to stop. A floating, nonactivating indicator stays visible. The shortcut can be changed in Settings; an occupied combination leaves the previous registration intact. Allow microphone access on the first recording.
3. After local transcription, words are sent to the field and selection captured at Stop. The app does not pop up or take focus. Web editors use one targeted Paste, even if they report writable `AXSelectedText`; native fields use direct selected-text replacement where supported, otherwise Paste. It checks process identity, element, selection, editability, and security before writing. Keep the destination unchanged while transcription finishes.
4. If insertion cannot proceed, the quiet indicator offers **Review** and **Copy**. Only choosing Review opens the app. You can turn off **Insert at cursor when dictation stops** in Settings. Closing/dismissing review or starting another session clears the in-memory transcript. Closing the window during recording leaves the visible indicator and menu controls running.

At Start, the app asks the foreground editor to expose its accessibility tree using Electron’s documented `AXManualAccessibility` handshake; it repeats preparation if you switch apps while recording. This does not capture a destination until Stop. Focus resolution verifies the process owner, and the secure-field check supports deep editor layouts within a 128-parent and 250 ms traversal budget. Missing ancestry and secure fields still block insertion.

Paste temporarily puts the transcript on the clipboard. Up to 8 MiB, 16 items, and 32 types per item are preserved in memory; declared promised-file data is rejected. Text is supplied when requested, with a two-second request timeout and a 500 ms restoration grace period after a request. Ownership-marker reads do not consume text. The previous contents are restored only while the clipboard change count and the app’s unique marker still match. A newer user/app copy is left alone. A clipboard manager can also request text, so neither a data request nor the grace period proves insertion; external editors and clipboard managers still need compatibility testing. No request observed means an ambiguous outcome, not permission to retry automatically.

The app never activates another app to deliver text, writes a whole document value, presses Return, submits a form, or retries an ambiguous insertion. Known terminals and secure fields are blocked. AX success or emitted Paste is an **insertion request**, not verified final text. A focus race across processes cannot be eliminated by these checks; live editor conformance remains a release gate.

**Cancel** immediately revokes delivery, stops capture, and terminates the worker. An unresponsive worker is killed after two seconds. Quit waits for normal cleanup. Cancel and Quit do not wait for an unanswered microphone permission request; any late response cannot start the cancelled session, though macOS controls the dialog itself. Recording automatically stops at the selected limit (five minutes maximum); the hard audio-frame cap also stops hardware if the UI timer is delayed. Device/format changes and sleep interrupt capture instead of silently resuming it.

Use **Command-comma** for Settings and **Command-Q** to quit. The Edit menu supports Copy and Select All in selectable text.

### Peak transcription memory

The main window retains **Transcription peak** after the engine exits. This is the engine worker's maximum resident set size (RSS), collected with macOS `wait4` / `ru_maxrss` when reaping the process, including workers too brief to appear in Activity Monitor. It includes model and engine working memory, excludes the GUI and system services, and is not Activity Monitor's physical-footprint metric or a combined app-tree peak. macOS reports this value in bytes; the UI formats it using memory units.

The reading survives dismissing a transcript and starting or cancelling another recording. It is replaced when another engine run returns successfully; unavailable measurements are explicitly labeled. Failed/cancelled engine runs leave the previous reading intact. The value stays in memory only and resets when the app quits. The info button explains its scope.

macOS 26 uses native Liquid Glass for primary controls and the floating indicator. Older systems and Reduce Transparency use opaque native surfaces. Transcript text remains on a solid background.

Local account authentication prompts: **zero**. A fresh packaged app needs microphone access and one Accessibility setup flow for cursor insertion; review-only mode needs no Accessibility access. The Carbon shortcut does not request Input Monitoring. No AppleScript Automation, Screen Recording, cloud account, API key, or subscription is required. The development bundle uses ad-hoc signing: its designated requirement is tied to the executable hash, so rebuilding can require renewed Accessibility approval. A stable bundle ID alone does not guarantee permission continuity; validate it after an update.

## Development and verification

```sh
swift build --package-path native/swift
swift test --package-path native/swift
native/swift/.build/debug/OpenWisper --check-profile --profile tools/engine/runtime/manifest.json
native/swift/.build/debug/OpenWisper --transcribe-wav /path/audio.wav --profile tools/engine/runtime/manifest.json
```

Check cursor-insertion readiness without recording, posting events, reading document text, or changing the clipboard:

```sh
'/Applications/Open Wisper Swift.app/Contents/MacOS/OpenWisper' --check-delivery
```

The report includes `automaticInsertion`, `accessibilityGranted`, `eligibleFocusedField`, a failure `reason`, and content-free role/ancestry metadata. When the GUI is running, `source` is `running Swift app`: the command queries that process without activating it or changing the session’s saved target. If the GUI does not reply within two seconds, the report explicitly identifies the standalone CLI, whose permissions macOS may attribute to the launching terminal. A false Accessibility result from the running app requires enabling **Open Wisper Swift.app** in System Settings → Privacy & Security → Accessibility. A false eligible-field result can simply mean Settings or another noneditable surface is focused. This command never prompts, records, reads document text, or pastes.

The CLI accepts mono 16 kHz signed 16-bit PCM RIFF WAV, including extra metadata chunks, up to five minutes. It prints only the requested transcript; errors contain no worker stdout/stderr. CLI paths never request microphone or Accessibility permission. Use the packaged app for live capture, so macOS grants permissions to the application identity.

UI render checks without microphone access:

```sh
native/swift/.build/debug/OpenWisper --render-preview /tmp/open-wisper.png
native/swift/.build/debug/OpenWisper --render-preview /tmp/open-wisper-settings.png --preview-settings
native/swift/.build/debug/OpenWisper --render-preview /tmp/open-wisper-memory.png --preview-memory
```

`--preview-memory` supplies an illustrative 128 MB reading for layout checks only. Add `--preview-light` or `--preview-compact` for light appearance or the 460 × 540 pt minimum content size. Offscreen bitmap renders do not capture compositor-rendered Liquid Glass reliably; verify glass controls in the running app.

Tests exercise lifecycle races, cancellation at every stage, stale completions, one-time delivery, permission denial and cancellation before an unanswered request completes, settings/shortcut rollback, WAV framing and native conversion, anti-alias rejection, bounded ring behavior, engine integrity, hostile worker output, timeout/escalation, process-group cleanup, and safe stale-file recovery. See [verification status](../../docs/swift-status.md) for actual results and remaining manual checks.

## Storage and recovery

Settings: `~/Library/Application Support/dev.akib.openwisper.swift/settings.json`, versioned, validated, atomically replaced, and mode `0600`. Version 1 preview settings adopt cursor insertion in memory while keeping the selected shortcut, engine, and limits; the next save writes version 2. A version 2 explicit opt-out is preserved. Unsupported/corrupt settings are preserved and must be moved aside explicitly before restarting. No transcript/audio history is persisted there.

Inference uses private `0700` directories named `session-<UUID>` within the current user's OS temporary directory, under `open-wisper-swift-sessions-v1-<uid>`. Only `.owner` and `audio.wav` are expected; files are `0600`. Normal completion, failure, cancellation, and timeout clean them up. Startup recovery removes recognized, unlocked entries older than 24 hours without following symlinks. Unknown contents are left untouched. If recovery reports a problem, inspect only that app-owned directory manually; do not delete arbitrary temporary folders. Deletion is not secure erasure, and abrupt OS/process termination can leave audio until recovery.

## Scope

Implemented: English local dictation, menu/status UI, registered configurable toggle shortcut, recording indicator, native audio conversion, cancellation/limits, supervised CLI, profile validation, cursor insertion with direct AX/guarded Paste, quiet review/Copy fallback, atomic settings, and content-free monotonic session timings.

Not implemented: hold/Fn-only shortcuts, device picker, resident/streaming inference, VAD, history, snippets, rewrite, launch-at-login, multilingual profiles, updater, or external comparative memory benchmarks. These remain separate planned work. The app is a functional development baseline; it does not claim Wispr parity or completion of the entire native release suite.
