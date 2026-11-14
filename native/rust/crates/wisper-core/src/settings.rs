use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static TEMPORARY_COUNTER: AtomicU64 = AtomicU64::new(0);

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
pub enum Model {
    #[serde(rename = "tiny.en-q5_1")]
    Tiny,
    #[serde(rename = "base.en")]
    Base,
    #[serde(rename = "small.en")]
    Small,
    #[serde(rename = "custom")]
    Custom,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Shortcut {
    pub key_code: u32,
    pub modifiers: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields, rename_all = "camelCase")]
pub struct Settings {
    pub version: u32,
    pub model: Model,
    pub engine_profile_path: String,
    pub shortcut: Shortcut,
    pub automatic_insertion: bool,
    pub worker_timeout_seconds: u32,
    pub maximum_duration_seconds: u32,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            version: 1,
            model: Model::Base,
            engine_profile_path: String::new(),
            shortcut: Shortcut {
                key_code: 49,
                modifiers: 3,
            },
            automatic_insertion: true,
            worker_timeout_seconds: 120,
            maximum_duration_seconds: 300,
        }
    }
}

impl Settings {
    pub fn validate(&self) -> io::Result<()> {
        let path = &self.engine_profile_path;
        if self.version != 1
            || ![49, 2, 9, 17, 1, 40, 37].contains(&self.shortcut.key_code)
            || self.shortcut.modifiers & !15 != 0
            || self.shortcut.modifiers & 13 == 0
            || !(1..=3600).contains(&self.worker_timeout_seconds)
            || !(1..=300).contains(&self.maximum_duration_seconds)
            || path.len() > 4096
            || path.chars().any(char::is_control)
            || (!path.is_empty() && !Path::new(path).is_absolute())
            || (self.model == Model::Custom && path.is_empty())
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid settings",
            ));
        }
        Ok(())
    }
}

pub struct SettingsStore {
    path: PathBuf,
}
impl SettingsStore {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }
    pub fn default_path(home: &Path) -> PathBuf {
        home.join("Library/Application Support/OpenWisper-Rust/settings-v1.json")
    }
    pub fn load(&self) -> io::Result<Settings> {
        let mut file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
            .open(&self.path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Settings::default()),
            Err(error) => return Err(error),
        };
        if !file.metadata()?.is_file() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "invalid settings file",
            ));
        }
        let mut bytes = Vec::new();
        Read::by_ref(&mut file)
            .take(65537)
            .read_to_end(&mut bytes)?;
        if bytes.len() > 65536 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "settings too large",
            ));
        }
        let settings: Settings = serde_json::from_slice(&bytes)?;
        settings.validate()?;
        Ok(settings)
    }
    pub fn save(&self, settings: &Settings) -> io::Result<()> {
        settings.validate()?;
        let parent = self
            .path
            .parent()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing parent"))?;
        fs::create_dir_all(parent)?;
        let temporary = parent.join(format!(
            ".settings-{}-{}",
            std::process::id(),
            TEMPORARY_COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        let result = (|| {
            file.write_all(&serde_json::to_vec(settings)?)?;
            file.sync_all()?;
            fs::rename(&temporary, &self.path)?;
            fs::File::open(parent)?.sync_all()?;
            Ok(())
        })();
        if result.is_err() {
            let _ = fs::remove_file(&temporary);
        }
        result
    }
}
