# Shared local speech engine

The Swift baseline uses whisper.cpp **v1.8.1**, commit `a91dd3be72f70dd1b3cb6e252f35fa17b93f596c`, and **tiny.en-q5_1**, English, CPU with Apple Accelerate, four threads, one short-lived process per utterance. The Electron MVP can use the same executable and model. Its decoding options must also match before making performance comparisons.

From the repository root:

```sh
python3 tools/engine/provision.py
```

This verifies the existing `mvp/tools/whisper.cpp` checkout, CMake configuration, runtime binary, and model, then writes `tools/engine/runtime/manifest.json`. It reuses artifacts in place. A second run checks the recorded hashes without downloading, rebuilding, or silently accepting changed files. No accounts or authentication are involved.

If the artifacts are absent, install the ordinary Xcode command-line tools and CMake first, then explicitly build and provision:

```sh
python3 tools/engine/provision.py --build
```

Only this provisioning mode may download missing public engine source and model files. It checks the exact source commit and model digest. Existing modified/wrong-version checkouts are rejected, not reset. The running application never downloads an engine or model.

For a complete existing offline profile:

```sh
python3 tools/engine/provision.py --import-profile /absolute/path/manifest.json
```

Imported paths are made absolute and their hashes checked. This imports a declaration, not proof that its declared build actually produced the executable. Keep the declared `provenance.kind` and limitations. Use `--output` for another manifest location, `--threads` for 1–64 threads on a newly created profile, and `--refresh` only to deliberately replace a recorded profile after reviewing changes. Unknown runtime schema fields and unsupported profiles are rejected by Swift's validator.

## Manifest v1

All fields are required. The runtime schema currently accepts only the pinned English tiny profile and CPU/CPU-Accelerate configurations:

- `schemaVersion`: `1`.
- `engine`, `sourceVersion`, `sourceCommit`: `whisper.cpp`, `v1.8.1`, and the exact commit above.
- `executable`: `path`, `sha256`.
- `model`: `path`, `sha256`, `name`, `license`, `licenseURL`.
- `architecture`: `arm64` or `x86_64`, matching the host.
- `buildFlags`: explicit `-DKEY=VALUE` CMake declarations, including backend choices.
- `threads`, `acceleration`, `language`, `residency`: thread count, `cpu`/`cpu-accelerate`, `en`, `short-lived`.
- `decodeArguments`: exact supported argv in `EngineManifest.decodingArguments`. It sets transcript-only stdout, no timestamps/GPU, beam/best-of 5, temperature 0, increment 0.2, and flash attention. The adapter separately supplies one processor, threads, language, and paths.
- `provenance`: `kind` (`local-build-metadata` or `operator-attested`), `evidence` (named SHA-256 values), and `limitations`.

The reference model SHA-256 is `c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b`. It identifies the observed local reference, not an upstream signature. The setup records the actual executable SHA-256; different toolchains may produce different hashes. A clean checkout, matching build output, and CMake evidence do not prove a fully reproducible build.

Artifact files must be ordinary readable files and cannot be group/world-writable. The engine must be executable. Arbitrary symlink traversal is rejected by the runtime; macOS's fixed `/var`, `/tmp`, and `/etc` aliases are supported. Relative paths resolve against the manifest; app packaging converts them to absolute paths.

whisper.cpp and the referenced Whisper model use MIT licenses; retain their upstream notices if distributing their artifacts. No project-wide distribution license is selected here. The default app bundle does not copy model weights or the engine.
