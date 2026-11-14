#![deny(unsafe_op_in_unsafe_fn)]

pub mod audio;
pub mod delivery;
pub mod hotkey;
pub mod permissions;

#[cfg(target_os = "macos")]
mod macos;

use std::{marker::PhantomData, rc::Rc};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PlatformError {
    Unsupported,
    MainThreadRequired,
    PermissionRequired,
    NativeFailure,
    InvalidShortcut,
    ShortcutUnavailable,
    ResourceLimit,
}

impl std::fmt::Display for PlatformError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for PlatformError {}

#[derive(Clone, Copy, Debug)]
pub struct MainThread(PhantomData<Rc<()>>);

impl MainThread {
    pub fn acquire() -> Result<Self, PlatformError> {
        #[cfg(target_os = "macos")]
        if unsafe { macos::pthread_main_np() } != 0 {
            return Ok(Self(PhantomData));
        }
        Err(PlatformError::MainThreadRequired)
    }
}
