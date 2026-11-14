# Open Wisper Rust

Independent native **macOS 14+** menu-bar dictation application. Rust owns AppKit,
capture, orchestration and process supervision; neither Swift nor Electron is
built or run. Apple Silicon is the verified build target, not a claim of tested
minimum-OS or Intel compatibility. The separate identity is
`dev.akib.openwisper.rust`.

## Build and validate

Install a normal Rust toolchain (Rust 1.85+), Xcode command-line SDK and Python 3.
From this directory, with `MACOSX_DEPLOYMENT_TARGET=14.0` exported:

```sh
cargo fmt --all --check
cargo test --locked --workspace
cargo clippy --locked --workspace --all-targets -- -D warnings
cargo build --locked --release --workspace
python3 scripts/test_build_app.py
target/release/OpenWisperRust --self-check
target/release/OpenWisperRust --check-profile --profile ../../tools/engine/runtime/manifest-tiny.en-q5_1.json
python3 scripts/build-app.py
```

The temporary toolchain used during development, **not a required change to your
shell configuration**, can be selected for the same commands:

```sh
export PATH=/tmp/open-wisper-cargo/bin:$PATH
export CARGO_HOME=/tmp/open-wisper-cargo
export RUSTUP_HOME=/tmp/open-wisper-rustup
export MACOSX_DEPLOYMENT_TARGET=14.0
```

The packager performs the release build itself; no separate build command is
needed when all you want is an app. It requires the already provisioned pinned
engine profile and **all three verified model caches**, defaulting to
`tools/engine/runtime/manifest.json` and `tools/engine/runtime/models` at repository
root. `--profile PATH` and `--cache DIRECTORY` override those inputs. Missing or
tampered caches fail without downloading anything. It reuses
`tools/engine/package_models.py`, signs the nested worker before recording its
digest, includes engine/model notices and dependency license texts, signs the app
ad hoc, verifies the bundle and all packaged profiles, then replaces only its own
marked, non-running bundle. No Apple account or certificate changes are made.

Output: `native/rust/dist/Open Wisper Rust.app`. Copy that complete bundle to
`~/Applications` or `/Applications` if desired, then launch it explicitly from
Finder. Preserve the bundle's Resources directory; raw `cargo run` has no bundled
models and requires an explicit Custom profile. The Rust and Swift apps share the
default shortcut, so quit the other variant or choose a different shortcut.

## Use and permissions

- Idle launch opens no window or indicator, requests no consent, captures nothing
  and reads no target/clipboard. Use the menu-bar circle to open Ready, Review or
  Settings, or choose Record / Stop. Default toggle: Command+Shift+Space.
- Record validates the selected local profile in a worker **before** requesting
  microphone access or beginning capture. `base.en` is the default; select
  `tiny.en-q5_1`, `small.en`, or an absolute Custom manifest path in Settings.
- A nonactivating petrol bottom pill shows the coordinator phase, real elapsed
  recording time, Stop and Cancel. Stop snapshots the focused target before
  synchronously draining capture; inference and WAV writing run off-main-thread.
  Capture is capped at the validated setting (default 300 seconds); inference has
  the validated deadline (default 120 seconds).
- For cursor insertion, leave the editor focused and stop with the shortcut or
  the nonactivating bottom pill. Opening Ready activates the Rust app; stopping
  from its Record/Stop button deliberately uses Review/Copy instead of guessing
  a previous editor. The Ready window explains this distinction.
- Automatic insertion is on by default and requires this **Rust** app's own
  Accessibility setup. Use Settings → Accessibility setup explicitly. Microphone
  and Accessibility are independent from the Swift app's grants. No accounts,
  passwords or MFA are needed for build or local transcription. macOS consent,
  and potentially Touch ID/password for Accessibility changes, remain unavoidable;
  changing an ad-hoc binary can require consent again. Keep one final bundle
  instead of repeatedly rebuilding/regranting during acceptance.
- Delivery is one guarded native AX selected-text request. **Automatic browser
  paste is not supported.** Web fields, unsafe/unknown targets, secure fields and
  terminals fall back conservatively to Review / Copy. No clipboard fallback,
  synthetic Return, focus switching or speculative retry occurs. “Insertion
  requested” is not proof the target inserted text.
- Completion/error never activates or opens Pebble. Click the pill status or menu
  explicitly to view the result/setup. Copy writes the current in-memory result to
  the system clipboard only on that action; Dismiss clears transcript and target.
  The native Edit menu supports focused UI editing and selection.
- Settings shortcut choices map explicitly from core modifier bits
  Command=1, Shift=2, Option=4, Control=8 to platform parsing. Registration is
  transactional; settings persist only after success, with rollback on save error.
  Invalid settings disable Record and visibly explain recovery on explicit open;
  they are not silently overwritten. Saving while a session is active is refused.

## Ownership, cancellation and privacy

`wisper-core` owns generation/state transitions, manifests, settings, WAV workspaces
and bounded worker supervision. `wisper-platform` owns audio, permission polling,
registered shortcuts, target snapshots, cancellation-gated delivery and explicit
Copy. The application owns native views and all transitions on the main thread;
capture/AX/hotkey objects never cross threads. One joinable worker validates or
transcribes at a time. Results carry the session generation and are applied only
after worker reaping; cancelled/stale results never start capture or deliver. A
replacement session waits for the previous worker. Cancel invalidates delivery
first and cancels permission, audio and inference. Quit uses the same path and
waits for core's TERM → two-second grace → KILL/reap supervision before exiting,
not an early process exit that could orphan inference. Hashing also checks the
cancellation token. OS/native teardown itself still requires live validation.

The app requires owned, non-symlink Application Support directories, a private
0700 `~/Library/Application Support/OpenWisper-Rust` and `sessions` directory, and
a 0600 `O_NOFOLLOW` flock file held for its lifetime. A second process exits with a
helpful error instead of recording. Core creates per-session owned private WAV
files and attempts to remove only its verified files on completion/cancellation.
Operation failures explicitly attempt cleanup before returning a result; a
cleanup failure warns that private audio may remain instead of promising removal.
There is no persisted text/history or content logging. The app never executes
transcripts as commands.

**Crash recovery limitation:** after force-kill/crash, private audio may remain in
`sessions`. Startup does not read or recursively delete it and reports its presence
in the explicitly opened window. Manually inspect/remove only those interrupted
session folders when no Rust app is running. No automatic recovery/deletion claim
is made. Lock files remain harmless after exit; flock ownership releases with the
descriptor.

## Validation boundary

Automated tests and `--self-check` exercise policy, shortcut mappings, generation
rejection, cancellation/one-time authorization, private storage and lock safety
without AppKit launch, permissions, microphone or input injection.
`--check-profile --profile PATH` checks actual manifest policy and engine/model
hashes, prints only content-free success/failure, and never starts AppKit. Packaging
runs this check on all three signed, relocatable bundled profiles.

**Not yet verified live:** packaged app/window launch, first-click focus behavior,
Dock/display/full-screen placement, native resizing/long transcript scrolling,
VoiceOver/contrast/dark appearance, shortcut conflicts and permission dialogs,
microphone/device switching and teardown, real editor/browser/secure-field matrix,
and wrong-target/duplicate/submission conformance. These remain manual release
gates, not implied by compile/test/signature checks. No Rust-versus-Swift resource
or transcription performance claim is made. Public distribution signing and
notarization are separate work.
