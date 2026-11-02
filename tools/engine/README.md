# Shared local speech engine

The Swift app uses whisper.cpp **v1.8.1**, commit `a91dd3be72f70dd1b3cb6e252f35fa17b93f596c`, English, CPU with Apple Accelerate, four threads, and one short-lived process per utterance. Packaging includes **tiny.en-q5_1**, **base.en** (the app default), and **small.en**. The Settings picker persists the offline model choice; existing explicit custom profiles remain supported. The Electron MVP can use the same source executable and models. Its decoding options must also match before making performance comparisons.

Model selection remains **experimental**. No controlled comparative accuracy, latency, or memory results are claimed. The bootstrap provisioner still creates/verifies a `small.en` source profile; the packager uses that profile's engine to create all three bundled profiles. It does not change the shared Electron configuration.

From the repository root:

```sh
python3 tools/engine/provision.py
```

This verifies the existing `mvp/tools/whisper.cpp` checkout, CMake configuration, runtime binary, and model, then writes `tools/engine/runtime/manifest.json`. It reuses artifacts in place. A second run checks the recorded hashes without downloading, rebuilding, or silently accepting changed files. No accounts or authentication are involved.

To refresh an existing tiny bootstrap profile, use `python3 tools/engine/provision.py --build --refresh`. This downloads the pinned `small.en` weights if missing and replaces the bootstrap manifest; keep the previous manifest and tiny weights if you want rollback. A plain provisioning verification deliberately rejects an old-model manifest instead of silently changing it. The Swift runtime itself accepts all three supported model names.

If the artifacts are absent, install the ordinary Xcode command-line tools and CMake first, then explicitly build and provision:

```sh
python3 tools/engine/provision.py --build
```

This provisioning mode may download missing public engine source and bootstrap model files. Packaging also downloads any missing models into `tools/engine/runtime/models` (override with `OPEN_WISPER_MODEL_CACHE`), using a pinned HTTPS revision and verified SHA-256. Existing modified/wrong-version checkouts are rejected, not reset. The running application never downloads an engine or model. Subsequent packaging uses the verified cache without logins or repeated downloads.

For a complete existing offline profile:

```sh
python3 tools/engine/provision.py --import-profile /absolute/path/manifest.json
```

Imported paths are made absolute and their hashes checked. This imports a declaration, not proof that its declared build actually produced the executable. Keep the declared `provenance.kind` and limitations. Use `--output` for another manifest location, `--threads` for 1–64 threads on a newly created profile, and `--refresh` only to deliberately replace a recorded profile after reviewing changes. Unknown runtime schema fields and unsupported profiles are rejected by Swift's validator.

## Manifest v1

All fields are required. The runtime schema accepts English `tiny.en-q5_1`, `base.en`, and `small.en` profiles with CPU/CPU-Accelerate configurations:

- `schemaVersion`: `1`.
- `engine`, `sourceVersion`, `sourceCommit`: `whisper.cpp`, `v1.8.1`, and the exact commit above.
- `executable`: `path`, `sha256`.
- `model`: `path`, `sha256`, `name`, `license`, `licenseURL`.
- `architecture`: `arm64` or `x86_64`, matching the host.
- `buildFlags`: explicit `-DKEY=VALUE` CMake declarations, including backend choices.
- `threads`, `acceleration`, `language`, `residency`: thread count, `cpu`/`cpu-accelerate`, `en`, `short-lived`.
- `decodeArguments`: exact supported argv in `EngineManifest.decodingArguments`. It sets transcript-only stdout, no timestamps/GPU, beam/best-of 5, temperature 0, increment 0.2, and flash attention. The adapter separately supplies one processor, threads, language, and paths.
- `provenance`: `kind` (`local-build-metadata` or `operator-attested`), `evidence` (named SHA-256 values), and `limitations`.

The default `small.en` model SHA-256 is `c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d`; its size is 487,614,201 bytes. Downloads are pinned to model repository revision `5359861c739e955e79d9a303bcbc70fb988958b1`. The previous tiny reference SHA-256 is `c77c5766f1cef09b6b7d47f21b546cbddd4157886b3b5d6d4f709e91e66c7c2b`. These identify artifacts, not upstream signatures. The setup records the actual executable SHA-256; different toolchains may produce different hashes. A clean checkout, matching build output, and CMake evidence do not prove a fully reproducible build.

The `base.en` SHA-256 is `a03779c86df3323075f5e796cb2ce5029f00ec8869eee3fdfb897afe36c6d002`, at the same immutable revision. `package_models.py` is the packaging digest catalog.

Artifact files must be ordinary readable files and cannot be group/world-writable. Packaged models use mode `0644`; the worker uses `0755`. Arbitrary symlink traversal is rejected by the runtime; macOS's fixed `/var`, `/tmp`, and `/etc` aliases are supported. Bundled manifests retain relative paths to the model in Resources and the worker in MacOS, so moving the app does not break them. Packaging rejects non-system dynamic dependencies. The nested worker is signed before its final hash is recorded; provenance retains the original source-engine hash. The outer bundle is signed last and verified recursively before replacing the stopped app.

whisper.cpp and the referenced Whisper models use MIT licenses; retain their upstream notices if distributing their artifacts. No project-wide distribution license is selected here. The default app bundle copies all three models and the engine; it no longer depends on source artifacts remaining on the developer's machine.
