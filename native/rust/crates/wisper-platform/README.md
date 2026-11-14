# wisper-platform

Independent Rust macOS adapters, with no dependency on `wisper-core`, Swift,
WebViews, AppleScript, event taps, accounts, models, or engine provisioning.
The application owns its coordinator, session IDs, single-instance lock, settings,
WAV encoding, transcription and UI. This library never launches capture or asks
for permissions merely because it is linked or loaded.

## Build and validation

Build for macOS 14+ using the Xcode command-line SDK. The manifest requires Rust
1.85 or later; validation used Rust 1.100.0 on Apple Silicon. Set
`MACOSX_DEPLOYMENT_TARGET=14.0` for the application and library build. Non-macOS
builds expose unsupported native capabilities, not simulated success.

```sh
export PATH=/tmp/open-wisper-cargo/bin:$PATH
export CARGO_HOME=/tmp/open-wisper-cargo
export RUSTUP_HOME=/tmp/open-wisper-rustup
export MACOSX_DEPLOYMENT_TARGET=14.0
cargo fmt --check --manifest-path native/rust/crates/wisper-platform/Cargo.toml
cargo test --manifest-path native/rust/crates/wisper-platform/Cargo.toml
```

Tests use synthetic samples and pure policy only. They do not query a real
focused field, read a clipboard, register a shortcut, request permissions, or
start a microphone. Native bindings are compiled and linked by these tests.
Live device, permission, editor and packaged-app acceptance is still required.

Pinned dependencies are `coreaudio-sys 0.2.18`, `rtrb 0.3.2`, `rubato 0.16.2`,
`objc2 0.6.3`, `objc2-foundation 0.3.2`, and `block2 0.6.2`. The package lockfile
records transitive resolution for standalone validation; the later application
workspace must retain its own authoritative lockfile. Versions and signatures
were checked against their published docs/source and the installed Apple SDK.
`coreaudio-sys` generates SDK bindings through bindgen/libclang at build time.
Only Foundation NSString/NSURL features are requested directly.

Capture directly owns an AUHAL Audio Unit rather than CPAL: source inspection
identified a listener retain cycle in CPAL 0.15.3, and callback buffer resizing in
the current CoreAudio wrapper. The independent implementation preallocates its
render buffer and fails on an oversized callback instead of resizing it.

## Threading and application integration

`MainThread::acquire() -> Result<MainThread, PlatformError>` checks the actual
OS main thread. Its private, non-Send/non-Sync marker gates AppKit operations.
Create a normal AppKit application/run loop and its autorelease pools in the app;
keep shortcuts and target snapshots on that thread. No app activation is done.

1. On launch, acquire the main-thread token and read permission statuses only.
   Do not call request/settings APIs or start capture automatically.
2. In an explicit Record action, if microphone status is `NotDetermined`, create
   one `MicrophoneRequest` and poll it from the main-loop timer. Do not wait on a
   condition variable or block the UI. Store the app session ID beside the request
   and ignore cancelled/stale results. Once authorized, call `CaptureSession::start`.
3. Keep the capture session on its owning thread (the native stream is non-Send).
   A 20–50 ms timer polls `status()`: Recording means continue; DurationLimit means
   visibly auto-Stop; Failed means stop/cancel and show a capture error. The frame
   cap stops accepting speech independently of that timer, but only teardown ends
   the hardware stream. Never ignore a failure or continue to transcription with
   a partial, overflowed capture.
4. On Stop, before changing focus or opening UI, call `TargetSnapshot::at_stop`.
   Preserve either its owned snapshot or its Review reason for that app session.
   Consume capture with `stop()` once. It synchronously stops/disposes hardware,
   joins the conversion worker, drains accepted frames and returns mono 16 kHz
   signed PCM16. The app/core writes its private WAV. Stop/cancel may briefly block
   on native teardown and the bounded conversion drain, never on permission waits.
5. Keep `GlobalHotkey` alive on the main thread. On the timer, consume presses via
   `while hotkey.take_pressed() { ... }` and send toggle commands to the coordinator.
   Only persist a new shortcut after `replace()` succeeds. Avoid two app variants
   registering the same shortcut.
6. Associate a new `DeliveryCancellation` and the non-cloneable target snapshot
   with each session. After the coordinator consumes its exactly-once delivery
   authorization, invoke `replace_selected_text` on the main thread. It consumes
   the snapshot and makes at most one AX write. Any Review outcome persists the
   transcript for explicit review/Copy; do not retry, paste, activate a target, or
   synthesize Return. `InsertionRequested` is not verified insertion.
7. Serialize Cancel/quit and delivery on the same main-thread coordinator. Cancel
   delivery before invalidating/dropping the snapshot, cancel a pending permission
   request, and consume the capture session with `cancel()`. A cloned delivery
   cancellation handle can invalidate pending work from another thread, but no
   cancellation can withdraw an AX IPC already begun. Never treat the atomic flag
   as a replacement for coordinator ordering/authorization.

## Public APIs

All names below are public under the indicated module. Errors are content-free
enums implementing Debug; `PlatformError`/`CaptureError` also implement Error.

```rust
permissions::microphone_status() -> MicrophoneStatus
permissions::accessibility_trusted() -> bool
permissions::MicrophoneRequest::request_from_user_action(&MainThread)
    -> Result<MicrophoneRequest, PlatformError>
MicrophoneRequest::poll(&self) -> Option<bool>
MicrophoneRequest::cancel(&self)
permissions::open_microphone_settings_from_user_action(&MainThread)
    -> Result<(), PlatformError>
permissions::open_accessibility_settings_from_user_action(&MainThread)
    -> Result<(), PlatformError>

audio::CaptureSession::start() -> Result<CaptureSession, CaptureError>
CaptureSession::status(&self) -> CaptureStatus
CaptureSession::stop(self) -> Result<CapturedAudio, CaptureError>
CaptureSession::cancel(self) -> Result<(), CaptureError>
CapturedAudio { samples: Vec<i16>, duration_limit_reached: bool }
CaptureStatus::{Recording, DurationLimit, Failed(CaptureError)}
audio::OUTPUT_RATE: u32 = 16_000
audio::MAX_SECONDS: usize = 300

hotkey::Shortcut::default() -> Shortcut
"Command+Shift+Space".parse::<hotkey::Shortcut>() -> Result<Shortcut, PlatformError>
hotkey::GlobalHotkey::new(&MainThread, Shortcut) -> Result<GlobalHotkey, PlatformError>
GlobalHotkey::replace(&mut self, Shortcut) -> Result<(), PlatformError>
GlobalHotkey::take_pressed(&mut self) -> bool

delivery::TargetSnapshot::at_stop(&MainThread) -> Result<TargetSnapshot, ReviewReason>
TargetSnapshot::replace_selected_text(self, &str, &DeliveryCancellation) -> DeliveryOutcome
delivery::DeliveryCancellation::default() -> DeliveryCancellation
DeliveryCancellation::cancel(&self)
DeliveryCancellation::is_cancelled(&self) -> bool
delivery::copy_from_user_action(&MainThread, &str) -> Result<(), PlatformError>
DeliveryOutcome::{InsertionRequested, Review(ReviewReason)}
delivery::MAX_TEXT_BYTES: usize = 1_048_576
```

`MicrophoneStatus` is NotDetermined, Restricted, Denied, Authorized or Unsupported.
Permission poll returns None while pending or cancelled, Some(true) for authorized,
Some(false) for denied/restricted. Drop cancels that waiter. macOS's already
presented permission sheet itself cannot be dismissed by cancelling a waiter;
its late callback only updates that request's isolated atomic result. Avoid
multiple concurrent requests and do not loop denied requests at launch.

The shortcut parser accepts case-insensitive Command/Cmd, Shift, Option/Alt and
Control/Ctrl, plus Space, A–Z or digits. At least Command, Option or Control is
required. Key codes are physical ANSI positions, not layout-derived characters.
Duplicates, multiple keys, Return, unsupported and modifier-only chords fail.
Registration uses Carbon press/release events with repeat suppression, no Input
Monitoring. Replacement acquires the new registration first; acquisition failure
retains the old one. Exceptional unregister failure poisons further replacements
while retaining the previous tracked registration. Drop unregisters/removes the
handler. Only one manager is supported per process.

## Capture bounds and lifetime

Only one owned hardware capture is supported per process. Each start creates new
callback state, ring, flags and conversion worker; there is no shared generation
mutable by old sessions. The device is the default input at Start. AUHAL output is
configured as interleaved native float32 at the device's integral 8–192 kHz rate,
with 1–32 channels. Core Audio performs any hardware sample-format adaptation.

The hardware callback only renders into a preallocated 8192-frame buffer,
validates counts, clips/downmixes finite samples and pushes mono frames into a
65,536-frame SPSC lock-free ring. No callback performs disk I/O, allocation,
logging, mutex acquisition or resampling. Oversized callbacks, invalid data,
ring overflow and native errors fail visibly through status/stop. A worker polls
device liveness, nominal rate, default-device identity and authorization every
100 ms, and flags three seconds without frames. Change/disconnect recovery is a
new session, never an invisible restart. The app must observe status promptly.

The worker uses Rubato's 256-tap Blackman-Harris sinc interpolator, zero-primes a
rational-rate period to align the first output frame, pads/flushes final input,
and truncates to the exact integral output
duration. Output capacity is preallocated for 4,800,000 PCM16 samples. The ring,
callback buffer and pending conversion block are fixed-size. No source-duration
float recording is accumulated. Stop/cancel/drop independently teardown their
owned unit and join the worker. If native disposal catastrophically fails, the
callback context is intentionally retained to avoid use-after-free and future
capture is disabled in that process; restart is required. No audio goes to disk
inside this crate.

## Conservative delivery boundary

Snapshot reads only frontmost application PID/bundle/launch date, AX focus,
role/subrole, enabled/settable metadata, selection range and parent ancestry.
It never reads AXValue, AXSelectedText or document text. CF-owned objects are
released by scoped owners, attribute types are checked, ancestry has a 48-node
cycle/depth bound, and each AX element receives a 50 ms messaging timeout.
An ancestry scan fails closed after a 350 ms elapsed budget (checked between
nodes); total synchronous latency can still include several native queries/timeouts.

Only AXTextField/AXTextArea with writable AXSelectedText and known nonsecure
ancestry are eligible. Missing role/non-root-subrole/parent/selection/process identity,
disabled fields, secure ancestors, changed process start identity, changed focus,
role or selection fail closed. Revalidation repeats the snapshot and checks
identity, element equality and selection before one AX write. A final global
focus check is required even when initial resolution used app-local focus.
An ambiguous AX error never triggers a retry. Native AX has no atomic
compare-and-set primitive: these guards are best-effort preconditions, not a
universal guarantee against another process changing focus during the IPC.

Any AXWebArea ancestry is Review/Copy only, even if AXSelectedText is writable.
Safe automatic Paste is **unsupported**: no lazy provider, clipboard snapshots,
Command-V injection, restoration, or clipboard reads exist. Explicit Copy is a
user-authorized plain-text clipboard overwrite, limited to 1 MiB; it does not
promise preservation of the old clipboard if setting the new item fails.

Control text is rejected; newline/tab/carriage-return text is additionally
rejected for terminals **and unknown applications**. Only the explicitly
recognized native document applications TextEdit and Notes permit multiline
replacement. This deliberately avoids maintaining an incomplete terminal deny
list. Their live acceptance checks remain unperformed. Unsupported cases preserve
Review/Copy, never broaden to a whole-value write or guessed destination.

Package the app separately as `dev.akib.openwisper.rust`, with
`NSMicrophoneUsageDescription`, appropriate hardened-runtime audio-input
entitlements if signing that way, and the application's required notices. No
permissions are borrowed from Swift. Baseline account login/MFA count is zero;
explicit microphone consent and Accessibility Settings may be needed once for
this app identity, and macOS may require local authentication for those settings.
No Accessibility prompt is requested at launch and no Input Monitoring grant is
needed. Re-signing/revocation may require renewed setup. The core/app, not this
crate, must own the Rust process single-instance lock.
