use crate::*;
use sha2::{Digest, Sha256};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

static COUNTER: AtomicU64 = AtomicU64::new(0);
struct TestDirectory(PathBuf);
impl TestDirectory {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "wisper-core-test-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
        Self(path)
    }
}
impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn settings_round_trip_and_rejection() {
    let directory = TestDirectory::new();
    let path = directory.0.join("settings.json");
    let store = SettingsStore::new(&path);
    let mut settings = Settings::default();
    assert_eq!(store.load().unwrap(), settings);
    settings.automatic_insertion = false;
    store.save(&settings).unwrap();
    assert_eq!(store.load().unwrap(), settings);
    assert_eq!(
        fs::metadata(&path).unwrap().permissions().mode() & 0o777,
        0o600
    );
    settings.shortcut.modifiers = 2;
    assert!(store.save(&settings).is_err());
    let mut json: serde_json::Value = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
    json["extra"] = true.into();
    fs::write(&path, serde_json::to_vec(&json).unwrap()).unwrap();
    assert!(store.load().is_err());
}

#[test]
fn workspace_writes_private_wav_and_only_owned_files() {
    let root = TestDirectory::new();
    let mut workspace = SessionWorkspace::create(&root.0).unwrap();
    workspace.write_pcm16(&[0, 1, -1]).unwrap();
    let audio = fs::read(workspace.audio_path()).unwrap();
    assert_eq!(&audio[..4], b"RIFF");
    assert_eq!(&audio[44..], &[0, 0, 1, 0, 255, 255]);
    assert_eq!(
        fs::metadata(workspace.audio_path())
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    let foreign = workspace.directory().join("foreign");
    fs::write(&foreign, b"keep").unwrap();
    assert!(workspace.cleanup().is_err());
    assert_eq!(fs::read(&foreign).unwrap(), b"keep");
    fs::remove_file(foreign).unwrap();
    workspace.cleanup().unwrap();
}

#[test]
fn manifest_strictly_checks_profile_and_artifacts() {
    let root = TestDirectory::new();
    let executable = root.0.join("worker");
    let model = root.0.join("model");
    fs::write(&executable, b"worker").unwrap();
    fs::set_permissions(&executable, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(&model, b"model").unwrap();
    let digest = |value: &[u8]| format!("{:x}", Sha256::digest(value));
    let profile = root.0.join("profile.json");
    let mut json = serde_json::json!({
        "schemaVersion": 1, "engine": "whisper.cpp", "sourceVersion": "v1.8.1", "sourceCommit": "a91dd3be72f70dd1b3cb6e252f35fa17b93f596c",
        "executable": {"path": "worker", "sha256": digest(b"worker")},
        "model": {"path": "model", "sha256": digest(b"model"), "name": "base.en", "license": "MIT", "licenseURL": "https://github.com/openai/whisper/blob/main/LICENSE"},
        "architecture": if cfg!(target_arch="aarch64") { "arm64" } else { "x86_64" },
        "buildFlags": ["-DCMAKE_BUILD_TYPE=Release", "-DBUILD_SHARED_LIBS=OFF", "-DGGML_CPU=ON", "-DGGML_BACKEND_DL=OFF", "-DGGML_METAL=OFF", "-DGGML_CUDA=OFF", "-DWHISPER_COREML=OFF", "-DWHISPER_OPENVINO=OFF", "-DWHISPER_CURL=OFF", "-DGGML_ACCELERATE=OFF", "-DGGML_BLAS=OFF", "-DGGML_HIP=OFF", "-DGGML_VULKAN=OFF", "-DGGML_SYCL=OFF", "-DGGML_RPC=OFF", "-DGGML_OPENCL=OFF", "-DGGML_WEBGPU=OFF", "-DGGML_MUSA=OFF"],
        "threads": 4, "acceleration": "cpu", "decodeArguments": ["--no-prints", "--no-timestamps", "--no-gpu", "--beam-size", "5", "--best-of", "5", "--temperature", "0", "--temperature-inc", "0.2", "--flash-attn"],
        "language": "en", "residency": "short-lived", "provenance": {"kind": "operator-attested", "evidence": {"source": digest(b"evidence")}, "limitations": "operator assertion"}
    });
    fs::write(&profile, serde_json::to_vec(&json).unwrap()).unwrap();
    let cancel = Cancellation::new();
    assert!(EngineManifest::load_validated(&profile, &cancel).is_ok());
    fs::write(&model, b"changed").unwrap();
    assert!(matches!(
        EngineManifest::load_validated(&profile, &cancel),
        Err(ManifestError::Integrity)
    ));
    json["unexpected"] = true.into();
    fs::write(&profile, serde_json::to_vec(&json).unwrap()).unwrap();
    assert!(matches!(
        EngineManifest::load(&profile),
        Err(ManifestError::Invalid)
    ));
    json.as_object_mut().unwrap().remove("unexpected");
    json["decodeArguments"][0] = "--help".into();
    fs::write(&profile, serde_json::to_vec(&json).unwrap()).unwrap();
    assert!(matches!(
        EngineManifest::load(&profile),
        Err(ManifestError::Invalid)
    ));
}
