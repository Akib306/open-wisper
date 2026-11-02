# Offline Whisper model selection implementation plan

## Contract

Ship three English CPU whisper.cpp models: tiny.en-q5_1, base.en (default), and small.en. The Settings picker chooses an offline Whisper model, not an Apple Speech backend. Existing schema-1 custom profiles and settings remain usable; an explicitly chosen custom profile remains selected until the user chooses a bundled model. Changes are allowed only while idle; a recording captures its profile when started.

## Implementation

1. Keep schema 1 and its architecture, provenance and artifact digest checks. Add base.en to the supported names and persist a backwards-compatible optional model choice.
2. Package one validated engine and three separate relative-path profiles and models. Fetch missing models over HTTPS at the pinned upstream revision, verify the published Git LFS SHA-256 before installation, and revalidate cached artifacts. A custom input profile supplies the validated engine metadata, not unverified model bytes.
3. Resolve the chosen bundled profile relative to the running app, preserve explicit external profiles, and validate before enabling transcription. Surface unavailable or damaged assets as errors, never silently fall back.
4. Add focused tests for settings migration, model validation, cache and package behavior; run Swift tests/build and Python tests.

Review hardening: construct a fresh staging bundle and verify it before replacing the stopped installation, with rollback if replacement fails. Reject non-system dynamic engine dependencies, place the worker in `Contents/MacOS`, sign it before recording its packaged hash and original-build provenance, then sign and recursively verify the outer bundle. Set models and manifests to `0644` and the worker to `0755`. Match only the exact legacy bundled manifest suffix when migrating settings, and cancel superseded background hash tasks.

## Distribution and failures

Models add about 668 MB (decimal) uncompressed, plus the executable and app; downloads occur only at package time and are cached locally. The installed app requires no model downloads, login, or account. Packaging fails for missing source profiles, download errors, hash mismatches, or unsupported engine architecture; runtime refuses missing, modified, or incompatible artifacts. SHA-256 checks establish identity against pinned published hashes, not upstream signing or reproducible-build authenticity. Keep binary and model assets out of git. Packaging changes do not alter signing or update behavior.
