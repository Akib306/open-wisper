use std::ffi::CString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

static COUNTER: AtomicU64 = AtomicU64::new(0);
pub struct SessionWorkspace {
    directory: PathBuf,
    root_fd: File,
    directory_fd: File,
    name: CString,
    device: u64,
    inode: u64,
    audio_identity: Option<(u64, u64)>,
    cleaned: bool,
}
impl SessionWorkspace {
    pub fn create(root: &Path) -> io::Result<Self> {
        let root_meta = fs::symlink_metadata(root)?;
        if !root_meta.is_dir()
            || root_meta.uid() != unsafe { libc::geteuid() }
            || root_meta.mode() & 0o077 != 0
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "workspace root must be private and owned",
            ));
        }
        let root_fd = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(root)?;
        let opened = root_fd.metadata()?;
        if (opened.dev(), opened.ino()) != (root_meta.dev(), root_meta.ino()) {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "workspace root changed",
            ));
        }
        for _ in 0..100 {
            let name = format!(
                "session-{}-{}",
                std::process::id(),
                COUNTER.fetch_add(1, Ordering::Relaxed)
            );
            let directory = root.join(name);
            let name = CString::new(directory.file_name().unwrap().as_bytes()).unwrap();
            if unsafe { libc::mkdirat(root_fd.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::AlreadyExists {
                    continue;
                }
                return Err(error);
            }
            let fd = unsafe {
                libc::openat(
                    root_fd.as_raw_fd(),
                    name.as_ptr(),
                    libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                )
            };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            let directory_fd = unsafe { File::from_raw_fd(fd) };
            let metadata = directory_fd.metadata()?;
            return Ok(Self {
                directory,
                root_fd,
                directory_fd,
                name,
                device: metadata.dev(),
                inode: metadata.ino(),
                audio_identity: None,
                cleaned: false,
            });
        }
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "workspace allocation failed",
        ))
    }
    pub fn directory(&self) -> &Path {
        &self.directory
    }
    pub fn audio_path(&self) -> PathBuf {
        self.directory.join("audio.wav")
    }
    pub fn write_pcm16(&mut self, samples: &[i16]) -> io::Result<()> {
        if self.cleaned
            || self.audio_identity.is_some()
            || samples.is_empty()
            || samples.len() > 16000 * 300
        {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid audio"));
        }
        self.check_directory()?;
        let fd = unsafe {
            libc::openat(
                self.directory_fd.as_raw_fd(),
                c"audio.wav".as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o600,
            )
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        let metadata = file.metadata()?;
        self.audio_identity = Some((metadata.dev(), metadata.ino()));
        let bytes = (samples.len() * 2) as u32;
        file.write_all(b"RIFF")?;
        file.write_all(&(36 + bytes).to_le_bytes())?;
        file.write_all(b"WAVEfmt ")?;
        file.write_all(&16u32.to_le_bytes())?;
        file.write_all(&1u16.to_le_bytes())?;
        file.write_all(&1u16.to_le_bytes())?;
        file.write_all(&16000u32.to_le_bytes())?;
        file.write_all(&32000u32.to_le_bytes())?;
        file.write_all(&2u16.to_le_bytes())?;
        file.write_all(&16u16.to_le_bytes())?;
        file.write_all(b"data")?;
        file.write_all(&bytes.to_le_bytes())?;
        for sample in samples {
            file.write_all(&sample.to_le_bytes())?;
        }
        file.sync_all()
    }
    pub fn cleanup(&mut self) -> io::Result<()> {
        if self.cleaned {
            return Ok(());
        }
        self.check_directory()?;
        if let Some(identity) = self.audio_identity {
            let metadata = fs::symlink_metadata(self.audio_path())?;
            if !metadata.is_file() || (metadata.dev(), metadata.ino()) != identity {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "audio ownership changed",
                ));
            }
            if unsafe { libc::unlinkat(self.directory_fd.as_raw_fd(), c"audio.wav".as_ptr(), 0) }
                != 0
            {
                return Err(io::Error::last_os_error());
            }
            self.audio_identity = None;
        }
        if unsafe {
            libc::unlinkat(
                self.root_fd.as_raw_fd(),
                self.name.as_ptr(),
                libc::AT_REMOVEDIR,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        self.cleaned = true;
        Ok(())
    }
    fn check_directory(&self) -> io::Result<()> {
        let metadata = fs::symlink_metadata(&self.directory)?;
        if !metadata.is_dir()
            || (metadata.dev(), metadata.ino()) != (self.device, self.inode)
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "workspace ownership changed",
            ));
        }
        Ok(())
    }
    pub(crate) fn validate_audio(&self) -> io::Result<()> {
        self.check_directory()?;
        let identity = self
            .audio_identity
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing audio"))?;
        let metadata = fs::symlink_metadata(self.audio_path())?;
        if !metadata.is_file()
            || (metadata.dev(), metadata.ino()) != identity
            || metadata.mode() & 0o077 != 0
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "audio ownership changed",
            ));
        }
        Ok(())
    }
}
impl Drop for SessionWorkspace {
    fn drop(&mut self) {
        let _ = self.cleanup();
    }
}
