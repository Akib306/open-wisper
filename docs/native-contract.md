# Native v1 behavior contract

Status: **v1 target contract**. The [Swift baseline](../native/swift/README.md) implements the core workflow; [verification status](swift-status.md) records remaining conformance and release work. Rust remains planned. This is our product contract, not a recovered Wispr specification.

## Product boundary

- macOS-first, initially Apple Silicon; select and validate the minimum OS during the platform spikes.
- Menu-bar application, settings/result review window, and a nonactivating recording indicator.
- Configurable registered combination shortcut; default `Command+Shift+Space`. Toggle recording first; hold-to-talk and Fn-only are later capabilities.
- Local transcription after explicit engine/model provisioning. No account, service key, subscription, or runtime download required for baseline dictation.
- Cursor insertion is the default workflow, following the user's October 31 correction. One explicit Accessibility setup enables delivery; explicit review/Copy remains available. Completion never activates the app automatically.
- Start with the same English model as the Electron baseline. Multilingual support is a separate tested profile.

## Visual direction

Visual direction is separately accepted in [ADR-0001](decisions/0001-native-ui-variants.md): Swift uses a compact Dynamic Island–inspired Bridge indicator; Rust uses an ordinary floating pill. Both open an independent Pebble window only on explicit user action. This visual choice does not change the behavioral ports, capture ownership, focus rules, or delivery guarantees below, and native UI integration remains pending.

## Ports

Both implementations provide equivalents of these interfaces, with independent implementation code:

| Port | Responsibility |
| --- | --- |
| `AudioCapture` | Own device/capture lifetime; supply bounded PCM frames and capture failures. |
| `Transcriber` | Accept normalized PCM/WAV plus engine profile; return raw text, timing, and typed error. |
| `TextTransform` | Identity by default; optional deterministic rules, vocabulary, snippets, or model-based rewrite. |
| `Delivery` | Snapshot/revalidate target; insert if authorized; otherwise expose explicit Copy/review. |
| `Permissions` | Report authorization/capability state; request only after the relevant user action. |
| `Hotkeys` | Transactionally replace registration and roll back on failure. |
| `SettingsStore` | Atomic versioned settings, validated values, no content-bearing logs. |
| `Metrics` | Monotonic timings, session outcomes, provenance, and externally sampled resource data. |

## Session state machine

```text
idle → preparing → recording → finalizing → transcribing
     → transforming → deliveryPending → completed → idle

Any active state → cancelling → cancelled → idle
Any active state → failed → idle
```

`transforming` is an identity operation unless enabled. One serialized coordinator owns transitions; views and hotkey callbacks issue commands rather than assigning phase. The indicator renders coordinator state and never owns capture.

Rules:

1. Assign an opaque session ID before asynchronous work. Every callback/result carries that ID; ignore stale completions.
2. Permit one active session. Repeated Start during preparing/recording is idempotent; repeated Stop during finalizing/transcribing is idempotent. Toggle during recording means Stop; Toggle during preparing or later processing does not start another session.
3. Cancel during any active stage invalidates delivery immediately. A result arriving after Cancel must never insert, even if the underlying inference cannot stop immediately.
4. Stop flushes exactly once, drains accepted frames, finalizes WAV headers, and starts at most one transcription.
5. Default maximum utterance duration: five minutes, then perform a visible automatic Stop. Never accumulate indefinitely. Bounded queues stop with an explicit capture error on overflow rather than silently dropping speech.
6. Proposed worker timeout: 120 seconds after spawn, independently configurable from recording duration. Cancel/quit requests termination immediately; escalate after two seconds if needed. Treat these as implementation acceptance targets, not measured behavior.
7. Never block an audio callback on conversion, allocation-heavy work, disk I/O, IPC, model inference, or UI work. Use preallocated buffers and bounded handoff; retain framework objects only on their valid execution context.
8. Closing settings does not alter capture. Quit stops capture, invalidates delivery, terminates supervised workers, and attempts owned temporary-file cleanup.

## Audio and engine profiles

Normalize to mono 16 kHz signed 16-bit little-endian PCM WAV for the baseline CLI adapter. Preserve chronological ordering, flush the final partial buffer, define clipping/downmix policy, and test duration against sample count. Use an anti-aliased converter; the MVP's linear interpolation is not the native quality reference.

Share an engine manifest containing exact source commit, executable SHA-256, model SHA-256, model license, architecture, build flags, thread count, acceleration, decoding arguments, language, and worker residency policy. A version label alone is insufficient. Baseline execution uses direct argv without a shell, bounded output, and an explicit working directory/environment.

Use private per-session directories and files for the CLI adapter. Put creation/writing inside cleanup-protected lifetime management. Normal completion, failure, cancel, and timeout remove owned files. Startup recovery only removes safely recognized application-owned stale entries without following symlinks; never recursively delete arbitrary user-supplied paths. Process crashes may leave files until recovery. Deletion is not secure erasure.

The primary proposed fixture profile is `whisper.cpp` v1.8.1 / `tiny.en-q5_1`, matching existing documentation; verify the actual commit and runtime/model hashes before adopting it. A separate `base.en` quantized profile measures quality trade-offs. Never silently substitute one model/build for another.

## Delivery safety

1. Snapshot target PID plus process-start identity, bundle identifier, focused element, role/editability, and selection context when recording stops, before asynchronous finalization/inference. This lets the user position the cursor while speaking. Avoid reading surrounding text.
2. The indicator must not activate its own app. If Stop occurs in our settings/review window, require an explicit target/review action rather than guessing a previous app. Completion, including errors or blocked insertion, presents a nonactivating indicator; only an explicit Review action opens the app.
3. Immediately before insertion, revalidate target/process/focus and secure-field policy. Changed, unknown, inaccessible, or secure contexts fall back to review. Do not reactivate another app or paste into a newly focused field.
4. Attempt selected-text replacement only where the focused AX element supports it and the adapter has been validated. Web content identified by an `AXWebArea` ancestor uses Paste instead: reported AX writability alone does not validate a web editor's insertion behavior. Never replace an entire document using a whole-value write as a fallback.
5. The insertion setting includes one Command-V for web content or an editable field without supported selected-text replacement. It temporarily changes the clipboard, rechecks focus immediately before posting to the captured process, and reports an input request rather than claiming observed insertion. If Paste cannot be prepared for web content, offer Copy rather than trying an unvalidated AX write. A timed-out AX write must never trigger Paste. There remains an unavoidable focus race between validation and injected input; treat this as a risk, not a safety guarantee.
6. Never press Return, execute a terminal command, submit a form, retry an ambiguous insertion, or deliver twice. In terminals, block automatic insertion of multiline/control-character content; offer Copy/review instead.
7. Snapshot/restore clipboard data only within explicit size/type bounds and only if its change counter and our marker still match. Otherwise leave the user's newer clipboard alone. Supply transcript text lazily, waiting up to two seconds for a data request before restoring; after a request, allow a further 500 ms grace period. Marker/ownership reads must not count as transcript reads. Cancellation or lost clipboard ownership ends the wait without another input request. A data request can come from a clipboard manager and is not proof of editor insertion. Do not promise universal clipboard restoration or use a fixed sleep as evidence of consumption.
8. Distinguish `reviewReady`, `copied`, `insertionRequested`, `insertionVerified`, `blocked`, `cancelled`, and `failed`. AX success or Command-V emission alone is not proof of the final editor text.

On an insertion attempt, atomically consume a session-scoped delivery authorization. Late duplicate callbacks and transport timeouts cannot acquire it again. An ambiguous outcome remains ambiguous until a safe readback or user decision resolves it.

## Privacy, persistence, and permissions

- Microphone capture is user-initiated and visibly indicated; no always-on background capture.
- No retained audio/transcripts/history by default after result dismissal. In-memory result review is distinct from persisted history.
- History is opt-in, with retention duration and deletion/export controls. Never add screenshot, URL, field-text, or clipboard-history capture by default.
- Content-free diagnostic events only. Explicit Copy/clipboard fallback discloses clipboard exposure to other applications.
- Permissions are feature-scoped: one microphone authorization flow on a fresh installation; one Accessibility setup flow when enabling insertion. Input Monitoring may add one flow if a chosen hotkey strategy needs it; avoid that strategy in v1 where possible.
- Expected local-account authentication count: **zero login/MFA prompts**. Permission flows are not authentication. OS revocation/re-signing can force renewed setup; do not loop requests on each launch.
- Two independently signed apps have separate identities and grants. Expect the setup sequence once per app, not a transferable permission grant. Validate actual OS dialogs/settings steps on packaged builds before promising an exact prompt count.
- No AppleScript Automation dependency in the proposed baseline. No Screen Recording, system-audio, camera, Bluetooth, cloud login, or screen-context permission request for basic dictation.

## Shared acceptance scenarios

Create original/consented fixtures and language-neutral command/event traces. Each track implements its own test runner against them. Check invariant-equivalent outputs, not incidental thread scheduling.

| Group | Required cases / pass condition |
| --- | --- |
| State/lifecycle | Rapid toggles, repeated Stop, Cancel at every stage, stale results, quit during inference; one session and no post-cancel delivery. |
| Audio | 44.1/48 kHz inputs, stereo/downmix, final short frame, silence, clipping, overflow, long utterance; validated conversion and bounded memory. |
| Devices | Unplug/reconnect, Bluetooth format change, device selection, sleep/wake, permission revocation; explicit recovery without invisible continued recording. |
| Engine | Missing/corrupt model, mismatched manifest, nonzero exit, hang, large stdout/stderr, cancellation; typed failure and supervised cleanup. |
| Target | Native field, browser plain text, contenteditable, terminal, secure field, app exit/PID reuse, selection/focus switch; fail closed or insert once into the intended supported target. |
| Clipboard | Rich clipboard, oversized/lazy data, clipboard manager race, user copies mid-delivery; no overwrite of newer data during restore. |
| Permission/setup | Deny microphone, deny Accessibility, revoke permissions, re-sign/update; no repeated prompt loops and honest feature availability. |
| Privacy | Offline capture/inference, content-free logs, no history by default, crash leftovers; no content egress and only owned cleanup. |
| Hotkey | Occupied shortcut, replacement failure, previous registration restoration; settings and actual registered key stay consistent. |

Zero wrong-target insertions, unintended submissions, and duplicate deliveries in this declared suite are release gates. Passing the suite is not a universal guarantee across every application.
