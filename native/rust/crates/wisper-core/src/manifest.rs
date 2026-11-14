use crate::Cancellation;
use serde::Deserialize;
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::ffi::CString;
use std::fs::File;
use std::io::{self, Read};
use std::os::fd::{FromRawFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::MetadataExt;
use std::path::{Component, Path, PathBuf};

#[derive(Debug)]
pub enum ManifestError {
    Invalid,
    Unsupported,
    Unavailable,
    Integrity,
    Cancelled,
}

#[derive(Clone, Debug, Eq, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Artifact {
    pub path: String,
    pub sha256: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct ModelArtifact {
    pub path: String,
    pub sha256: String,
    pub name: String,
    pub license: String,
    #[serde(rename = "licenseURL")]
    pub license_url: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Provenance {
    pub kind: String,
    pub evidence: HashMap<String, String>,
    pub limitations: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct EngineManifest {
    pub schema_version: u32,
    pub engine: String,
    pub source_version: String,
    pub source_commit: String,
    pub executable: Artifact,
    pub model: ModelArtifact,
    pub architecture: String,
    pub build_flags: Vec<String>,
    pub threads: u32,
    pub acceleration: String,
    pub decode_arguments: Vec<String>,
    pub language: String,
    pub residency: String,
    pub provenance: Provenance,
}
#[derive(Clone, Debug)]
pub struct ValidatedEngineProfile {
    pub(crate) manifest: EngineManifest,
    pub(crate) executable: PathBuf,
    pub(crate) model: PathBuf,
    pub(crate) profile_path: PathBuf,
}

impl ValidatedEngineProfile {
    pub fn manifest(&self) -> &EngineManifest {
        &self.manifest
    }
    pub fn executable(&self) -> &Path {
        &self.executable
    }
    pub fn model(&self) -> &Path {
        &self.model
    }
    pub fn revalidate(&self, cancellation: &Cancellation) -> Result<Self, ManifestError> {
        let checked = EngineManifest::load_validated(&self.profile_path, cancellation)?;
        if checked.manifest != self.manifest
            || checked.executable != self.executable
            || checked.model != self.model
        {
            return Err(ManifestError::Integrity);
        }
        Ok(checked)
    }
}

fn digest_valid(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}
fn path_valid(value: &str) -> bool {
    !value.is_empty() && value.len() <= 4096 && !value.chars().any(char::is_control)
}
const DECODE: &[&str] = &[
    "--no-prints",
    "--no-timestamps",
    "--no-gpu",
    "--beam-size",
    "5",
    "--best-of",
    "5",
    "--temperature",
    "0",
    "--temperature-inc",
    "0.2",
    "--flash-attn",
];

impl EngineManifest {
    pub fn load(path: &Path) -> Result<Self, ManifestError> {
        let mut file = open_regular(path).map_err(|_| ManifestError::Invalid)?;
        let mut data = Vec::new();
        Read::by_ref(&mut file)
            .take(65537)
            .read_to_end(&mut data)
            .map_err(|_| ManifestError::Invalid)?;
        if data.len() > 65536 {
            return Err(ManifestError::Invalid);
        }
        let manifest: Self = serde_json::from_slice(&data).map_err(|_| ManifestError::Invalid)?;
        manifest.validate_schema()?;
        Ok(manifest)
    }
    pub fn validate_schema(&self) -> Result<(), ManifestError> {
        if self.schema_version != 1
            || self.engine != "whisper.cpp"
            || self.source_version != "v1.8.1"
            || self.source_commit != "a91dd3be72f70dd1b3cb6e252f35fa17b93f596c"
            || !["arm64", "x86_64"].contains(&self.architecture.as_str())
            || !(1..=64).contains(&self.threads)
            || !["cpu", "cpu-accelerate"].contains(&self.acceleration.as_str())
            || self.language != "en"
            || self.residency != "short-lived"
            || self
                .decode_arguments
                .iter()
                .map(String::as_str)
                .ne(DECODE.iter().copied())
            || !["tiny.en-q5_1", "base.en", "small.en"].contains(&self.model.name.as_str())
            || self.model.license != "MIT"
            || self.model.license_url != "https://github.com/openai/whisper/blob/main/LICENSE"
            || !path_valid(&self.executable.path)
            || !path_valid(&self.model.path)
            || !digest_valid(&self.executable.sha256)
            || !digest_valid(&self.model.sha256)
            || !["local-build-metadata", "operator-attested"]
                .contains(&self.provenance.kind.as_str())
            || self.provenance.evidence.is_empty()
            || self.provenance.evidence.len() > 32
            || self
                .provenance
                .evidence
                .iter()
                .any(|(key, value)| key.is_empty() || key.len() > 128 || !digest_valid(value))
            || self.provenance.limitations.is_empty()
            || self.provenance.limitations.len() > 2048
            || self.build_flags.is_empty()
            || self.build_flags.len() > 256
        {
            return Err(ManifestError::Invalid);
        }
        let mut flags = HashMap::new();
        for flag in &self.build_flags {
            if flag.len() > 512 || flag.chars().any(char::is_control) {
                return Err(ManifestError::Invalid);
            }
            let (key, value) = flag
                .strip_prefix("-D")
                .and_then(|item| item.split_once('='))
                .ok_or(ManifestError::Invalid)?;
            if key.is_empty() || value.is_empty() || flags.insert(key, value).is_some() {
                return Err(ManifestError::Invalid);
            }
        }
        let accelerated = if self.acceleration == "cpu-accelerate" {
            "ON"
        } else {
            "OFF"
        };
        for (key, value) in [
            ("CMAKE_BUILD_TYPE", "Release"),
            ("BUILD_SHARED_LIBS", "OFF"),
            ("GGML_CPU", "ON"),
            ("GGML_BACKEND_DL", "OFF"),
            ("GGML_METAL", "OFF"),
            ("GGML_CUDA", "OFF"),
            ("WHISPER_COREML", "OFF"),
            ("WHISPER_OPENVINO", "OFF"),
            ("WHISPER_CURL", "OFF"),
            ("GGML_ACCELERATE", accelerated),
            ("GGML_BLAS", accelerated),
            ("GGML_HIP", "OFF"),
            ("GGML_VULKAN", "OFF"),
            ("GGML_SYCL", "OFF"),
            ("GGML_RPC", "OFF"),
            ("GGML_OPENCL", "OFF"),
            ("GGML_WEBGPU", "OFF"),
            ("GGML_MUSA", "OFF"),
        ] {
            if flags.get(key) != Some(&value) {
                return Err(ManifestError::Invalid);
            }
        }
        Ok(())
    }
    pub fn load_validated(
        path: &Path,
        cancellation: &Cancellation,
    ) -> Result<ValidatedEngineProfile, ManifestError> {
        let profile_path = absolute(path).map_err(|_| ManifestError::Invalid)?;
        let manifest = Self::load(&profile_path)?;
        let host = if cfg!(target_arch = "aarch64") {
            "arm64"
        } else if cfg!(target_arch = "x86_64") {
            "x86_64"
        } else {
            "unsupported"
        };
        if manifest.architecture != host {
            return Err(ManifestError::Unsupported);
        }
        let parent = profile_path.parent().ok_or(ManifestError::Invalid)?;
        let executable = absolute(&parent.join(&manifest.executable.path))
            .map_err(|_| ManifestError::Invalid)?;
        let model =
            absolute(&parent.join(&manifest.model.path)).map_err(|_| ManifestError::Invalid)?;
        verify(&executable, &manifest.executable.sha256, true, cancellation)?;
        verify(&model, &manifest.model.sha256, false, cancellation)?;
        Ok(ValidatedEngineProfile {
            manifest,
            executable,
            model,
            profile_path,
        })
    }
}

fn absolute(path: &Path) -> io::Result<PathBuf> {
    let input = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()?.join(path)
    };
    let mut result = PathBuf::from("/");
    for component in input.components() {
        match component {
            Component::Normal(part) => result.push(part),
            Component::ParentDir => {
                result.pop();
            }
            _ => {}
        }
    }
    #[cfg(target_os = "macos")]
    if let Ok(rest) = result.strip_prefix("/") {
        if matches!(rest.components().next(), Some(Component::Normal(first)) if ["tmp", "var", "etc"].iter().any(|name| first == *name))
        {
            result = Path::new("/private").join(rest);
        }
    }
    Ok(result)
}

fn open_regular(path: &Path) -> io::Result<File> {
    let path = absolute(path)?;
    let root = unsafe {
        libc::open(
            c"/".as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC,
        )
    };
    if root < 0 {
        return Err(io::Error::last_os_error());
    }
    let mut directory = unsafe { File::from_raw_fd(root) };
    let components: Vec<_> = path
        .components()
        .filter_map(|component| {
            if let Component::Normal(name) = component {
                Some(name)
            } else {
                None
            }
        })
        .collect();
    if components.is_empty() {
        return Err(io::ErrorKind::InvalidInput.into());
    }
    use std::os::fd::AsRawFd;
    for (index, component) in components.iter().enumerate() {
        let name = CString::new(component.as_bytes()).map_err(|_| io::ErrorKind::InvalidInput)?;
        let flags = libc::O_RDONLY
            | libc::O_CLOEXEC
            | libc::O_NOFOLLOW
            | if index + 1 == components.len() {
                libc::O_NONBLOCK
            } else {
                libc::O_DIRECTORY
            };
        let fd: RawFd = unsafe { libc::openat(directory.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        directory = unsafe { File::from_raw_fd(fd) };
    }
    if !directory.metadata()?.is_file() {
        return Err(io::ErrorKind::InvalidData.into());
    }
    Ok(directory)
}

fn verify(
    path: &Path,
    expected: &str,
    executable: bool,
    cancellation: &Cancellation,
) -> Result<(), ManifestError> {
    let mut file = open_regular(path).map_err(|_| ManifestError::Unavailable)?;
    let before = file.metadata().map_err(|_| ManifestError::Unavailable)?;
    if before.len() == 0
        || before.len() > 5_368_709_120
        || before.mode() & 0o022 != 0
        || (executable && before.mode() & 0o111 == 0)
    {
        return Err(ManifestError::Unavailable);
    }
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65536];
    let mut total = 0u64;
    loop {
        if cancellation.is_cancelled() {
            return Err(ManifestError::Cancelled);
        }
        let count = file
            .read(&mut buffer)
            .map_err(|_| ManifestError::Unavailable)?;
        if count == 0 {
            break;
        }
        total += count as u64;
        if total > before.len() {
            return Err(ManifestError::Integrity);
        }
        hasher.update(&buffer[..count]);
    }
    let after = file.metadata().map_err(|_| ManifestError::Unavailable)?;
    if total != before.len()
        || before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
        || format!("{:x}", hasher.finalize()) != expected
    {
        return Err(ManifestError::Integrity);
    }
    Ok(())
}
