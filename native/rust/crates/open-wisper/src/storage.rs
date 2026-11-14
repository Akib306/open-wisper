use std::fs::{self, DirBuilder, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, OpenOptionsExt};
use std::path::Path;

pub fn private_directory(path: &Path) -> io::Result<()> {
    match DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => (),
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => (),
        Err(error) => return Err(error),
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_dir()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.mode() & 0o077 != 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "Private directory is unsafe; no files were removed.",
        ));
    }
    Ok(())
}

pub fn finish_workspace<Output>(
    workspace: &mut wisper_core::SessionWorkspace,
    result: Result<Output, String>,
) -> Result<Output, String> {
    match workspace.cleanup() {
        Ok(()) => result.map_err(|message| format!("{message} Private audio cleanup completed.")),
        Err(_) => {
            let warning = "Private session cleanup failed. Audio may remain in the private sessions folder; inspect it when the app is stopped.";
            Err(match result {
                Ok(_) => warning.to_owned(),
                Err(message) => format!("{message} {warning}"),
            })
        }
    }
}

pub struct InstanceLock(File);

impl InstanceLock {
    pub fn acquire(root: &Path) -> io::Result<Self> {
        private_directory(root)?;
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(root.join("instance.lock"))?;
        let metadata = file.metadata()?;
        if !metadata.is_file()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.mode() & 0o077 != 0
            || metadata.nlink() != 1
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Unsafe instance lock.",
            ));
        }
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "Open Wisper Rust is already running; use its menu-bar icon.",
            ));
        }
        Ok(Self(file))
    }
}

impl Drop for InstanceLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_operation_reports_failed_audio_cleanup() {
        let root =
            std::env::temp_dir().join(format!("wisper-app-failed-cleanup-{}", std::process::id()));
        private_directory(&root).unwrap();
        let mut workspace = wisper_core::SessionWorkspace::create(&root).unwrap();
        workspace.write_pcm16(&[1, 2, 3]).unwrap();
        let moved = root.join("interrupted-session");
        fs::rename(workspace.directory(), &moved).unwrap();
        let result: Result<(), String> =
            finish_workspace(&mut workspace, Err("Local transcription failed.".into()));
        let message = result.unwrap_err();
        assert!(message.contains("Local transcription failed."));
        assert!(message.contains("cleanup failed"));
        assert!(message.contains("Audio may remain"));
        assert!(moved.join("audio.wav").is_file());
        drop(workspace);
        fs::remove_file(moved.join("audio.wav")).unwrap();
        fs::remove_dir(moved).unwrap();
        fs::remove_dir(root).unwrap();
    }

    #[test]
    fn failed_operation_confirms_only_completed_audio_cleanup() {
        let root = std::env::temp_dir().join(format!(
            "wisper-app-confirmed-cleanup-{}",
            std::process::id()
        ));
        private_directory(&root).unwrap();
        let mut workspace = wisper_core::SessionWorkspace::create(&root).unwrap();
        workspace.write_pcm16(&[1, 2, 3]).unwrap();
        let session_path = workspace.directory().to_owned();
        let result: Result<(), String> =
            finish_workspace(&mut workspace, Err("Local transcription failed.".into()));
        let message = result.unwrap_err();
        assert!(message.contains("Local transcription failed."));
        assert!(message.contains("Private audio cleanup completed."));
        assert!(!session_path.exists());
        drop(workspace);
        fs::remove_dir(root).unwrap();
    }

    #[test]
    fn locks_exclude_and_refuse_symlinks() {
        let root = std::env::temp_dir().join(format!("wisper-app-lock-{}", std::process::id()));
        let first = InstanceLock::acquire(&root).unwrap();
        assert!(InstanceLock::acquire(&root).is_err());
        drop(first);
        let second = InstanceLock::acquire(&root).unwrap();
        drop(second);
        fs::remove_file(root.join("instance.lock")).unwrap();
        std::os::unix::fs::symlink("/dev/null", root.join("instance.lock")).unwrap();
        assert!(InstanceLock::acquire(&root).is_err());
        fs::remove_file(root.join("instance.lock")).unwrap();
        fs::remove_dir(root).unwrap();
    }
}
