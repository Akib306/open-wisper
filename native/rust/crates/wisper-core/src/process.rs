use crate::{ManifestError, SessionWorkspace, ValidatedEngineProfile};
use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};
use std::time::{Duration, Instant};

#[derive(Clone, Default)]
pub struct Cancellation(Arc<AtomicBool>);
impl Cancellation {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

#[derive(Debug)]
pub enum ProcessError {
    Manifest(ManifestError),
    InvalidAudio,
    InvalidTimeout,
    Launch,
    Cancelled,
    TimedOut,
    OutputLimit,
    InvalidOutput,
    EmptyOutput,
    Exit(i32),
    Signalled(i32),
    Supervision,
}
pub struct Transcription {
    pub text: String,
    pub elapsed: Duration,
}

pub fn transcribe(
    profile: &ValidatedEngineProfile,
    workspace: &SessionWorkspace,
    cancellation: &Cancellation,
    timeout: Duration,
) -> Result<Transcription, ProcessError> {
    if timeout.is_zero() || timeout > Duration::from_secs(3600) {
        return Err(ProcessError::InvalidTimeout);
    }
    let checked = profile.revalidate(cancellation).map_err(|error| {
        if matches!(error, ManifestError::Cancelled) {
            ProcessError::Cancelled
        } else {
            ProcessError::Manifest(error)
        }
    })?;
    workspace
        .validate_audio()
        .map_err(|_| ProcessError::InvalidAudio)?;
    if cancellation.is_cancelled() {
        return Err(ProcessError::Cancelled);
    }
    let mut command = Command::new(&checked.executable);
    command
        .args(&checked.manifest.decode_arguments)
        .args([
            "--threads",
            &checked.manifest.threads.to_string(),
            "--processors",
            "1",
            "--language",
            "en",
            "--model",
        ])
        .arg(&checked.model)
        .arg("--file")
        .arg(workspace.audio_path());
    command
        .current_dir(workspace.directory())
        .env_clear()
        .env("PATH", "/usr/bin:/bin")
        .env("HOME", workspace.directory())
        .env("TMPDIR", workspace.directory())
        .env("LANG", "en_US.UTF-8")
        .env("LC_ALL", "en_US.UTF-8")
        .env("OMP_NUM_THREADS", checked.manifest.threads.to_string())
        .env(
            "VECLIB_MAXIMUM_THREADS",
            checked.manifest.threads.to_string(),
        );
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    run(command, cancellation, timeout)
}

fn run(
    mut command: Command,
    cancellation: &Cancellation,
    timeout: Duration,
) -> Result<Transcription, ProcessError> {
    unsafe {
        command.pre_exec(|| {
            if libc::setpgid(0, 0) == 0 {
                Ok(())
            } else {
                Err(io::Error::last_os_error())
            }
        });
    }
    let start = Instant::now();
    let mut child = command.spawn().map_err(|_| ProcessError::Launch)?;
    let group = child.id() as libc::pid_t;
    let mut stdout = child.stdout.take().ok_or(ProcessError::Supervision)?;
    let mut stderr = child.stderr.take().ok_or(ProcessError::Supervision)?;
    for fd in [stdout.as_raw_fd(), stderr.as_raw_fd()] {
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        if flags < 0 || unsafe { libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) } < 0 {
            unsafe {
                libc::kill(-group, libc::SIGKILL);
            }
            let _ = child.wait();
            return Err(ProcessError::Supervision);
        }
    }
    let mut output = Vec::new();
    let mut error_bytes = Vec::new();
    let mut open = [true, true];
    let mut status = None;
    let mut failure = None;
    let mut termination = None;
    loop {
        if failure.is_none() {
            if cancellation.is_cancelled() {
                failure = Some(ProcessError::Cancelled);
            } else if start.elapsed() >= timeout {
                failure = Some(ProcessError::TimedOut);
            }
        }
        if failure.is_some() && termination.is_none() {
            unsafe {
                libc::kill(-group, libc::SIGTERM);
            }
            termination = Some(Instant::now());
        }
        if let Some(when) = termination {
            if when.elapsed() >= Duration::from_secs(2) {
                unsafe {
                    libc::kill(-group, libc::SIGKILL);
                }
                let _ = child.wait();
                return Err(failure.unwrap_or(ProcessError::Supervision));
            }
        }
        for (index, is_open) in open.iter_mut().enumerate() {
            if !*is_open {
                continue;
            }
            let mut buffer = [0u8; 8192];
            let result = if index == 0 {
                stdout.read(&mut buffer)
            } else {
                stderr.read(&mut buffer)
            };
            match result {
                Ok(0) => *is_open = false,
                Ok(count) => {
                    let target = if index == 0 {
                        &mut output
                    } else {
                        &mut error_bytes
                    };
                    if target.len() + count > 1024 * 1024 {
                        if failure.is_none() {
                            failure = Some(ProcessError::OutputLimit);
                        }
                    } else {
                        target.extend_from_slice(&buffer[..count]);
                    }
                }
                Err(error)
                    if error.kind() == io::ErrorKind::WouldBlock
                        || error.kind() == io::ErrorKind::Interrupted => {}
                Err(_) => {
                    *is_open = false;
                    if failure.is_none() {
                        failure = Some(ProcessError::Supervision);
                    }
                }
            }
        }
        if status.is_none() {
            match child.try_wait() {
                Ok(value) => {
                    if value.is_some() && failure.is_none() {
                        unsafe {
                            libc::kill(-group, libc::SIGKILL);
                        }
                    }
                    status = value;
                }
                Err(_) => {
                    if failure.is_none() {
                        failure = Some(ProcessError::Supervision);
                    }
                }
            }
        }
        if let Some(exit) = status.filter(|_| !open[0] && !open[1] && failure.is_none()) {
            if !exit.success() {
                return Err(if let Some(signal) = exit.signal() {
                    ProcessError::Signalled(signal)
                } else {
                    ProcessError::Exit(exit.code().unwrap_or(-1))
                });
            }
            let text = String::from_utf8(output).map_err(|_| ProcessError::InvalidOutput)?;
            if text.chars().any(|character| {
                (character.is_control() && !matches!(character, '\t' | '\n' | '\r'))
                    || character == '\u{7f}'
            }) {
                return Err(ProcessError::InvalidOutput);
            }
            let text = text.trim().to_owned();
            if text.is_empty() {
                return Err(ProcessError::EmptyOutput);
            }
            return Ok(Transcription {
                text,
                elapsed: start.elapsed(),
            });
        }
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn shell(script: &str) -> Command {
        let mut command = Command::new("/bin/sh");
        command
            .arg("-c")
            .arg(script)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        command
    }
    #[test]
    fn result_and_exit_are_distinct() {
        let cancel = Cancellation::new();
        assert_eq!(
            run(
                shell("printf '  hello\\n'"),
                &cancel,
                Duration::from_secs(5)
            )
            .unwrap()
            .text,
            "hello"
        );
        assert!(matches!(
            run(shell("exit 3"), &cancel, Duration::from_secs(5)),
            Err(ProcessError::Exit(3))
        ));
        assert!(matches!(
            run(shell("exit 0"), &cancel, Duration::from_secs(5)),
            Err(ProcessError::EmptyOutput)
        ));
    }
    #[test]
    fn timeout_and_cancellation_terminate_workers() {
        let cancel = Cancellation::new();
        assert!(matches!(
            run(shell("sleep 10"), &cancel, Duration::from_millis(30)),
            Err(ProcessError::TimedOut)
        ));
        let signal = cancel.clone();
        let thread = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(30));
            signal.cancel();
        });
        assert!(matches!(
            run(shell("sleep 10"), &cancel, Duration::from_secs(10)),
            Err(ProcessError::Cancelled)
        ));
        thread.join().unwrap();
    }
    #[test]
    fn concurrent_streams_are_bounded() {
        let cancel = Cancellation::new();
        assert!(matches!(run(shell("while :; do printf '01234567890123456789012345678901'; printf '01234567890123456789012345678901' >&2; done"), &cancel, Duration::from_secs(10)), Err(ProcessError::OutputLimit)));
    }
}
