use crate::{MainThread, PlatformError};
use std::sync::{
    atomic::{AtomicBool, AtomicU8, Ordering},
    Arc,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MicrophoneStatus {
    NotDetermined,
    Restricted,
    Denied,
    Authorized,
    Unsupported,
}

pub fn microphone_status() -> MicrophoneStatus {
    #[cfg(target_os = "macos")]
    {
        crate::macos::microphone_status()
    }
    #[cfg(not(target_os = "macos"))]
    {
        MicrophoneStatus::Unsupported
    }
}

pub fn accessibility_trusted() -> bool {
    #[cfg(target_os = "macos")]
    {
        unsafe { crate::macos::AXIsProcessTrusted() != 0 }
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

pub struct MicrophoneRequest {
    result: Arc<AtomicU8>,
    cancelled: Arc<AtomicBool>,
}

impl MicrophoneRequest {
    pub fn request_from_user_action(_main: &MainThread) -> Result<Self, PlatformError> {
        let request = Self {
            result: Arc::new(AtomicU8::new(0)),
            cancelled: Arc::new(AtomicBool::new(false)),
        };
        #[cfg(target_os = "macos")]
        {
            match microphone_status() {
                MicrophoneStatus::Authorized => request.result.store(1, Ordering::Release),
                MicrophoneStatus::NotDetermined => {
                    crate::macos::request_microphone(request.result.clone())
                }
                _ => request.result.store(2, Ordering::Release),
            }
            Ok(request)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = request;
            Err(PlatformError::Unsupported)
        }
    }

    pub fn poll(&self) -> Option<bool> {
        if self.cancelled.load(Ordering::Acquire) {
            return None;
        }
        match self.result.load(Ordering::Acquire) {
            1 => Some(true),
            2 => Some(false),
            _ => None,
        }
    }

    pub fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
}

impl Drop for MicrophoneRequest {
    fn drop(&mut self) {
        self.cancel();
    }
}

pub fn open_accessibility_settings_from_user_action(
    main: &MainThread,
) -> Result<(), PlatformError> {
    #[cfg(target_os = "macos")]
    {
        crate::macos::open_settings(
            main,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = main;
        Err(PlatformError::Unsupported)
    }
}

pub fn open_microphone_settings_from_user_action(main: &MainThread) -> Result<(), PlatformError> {
    #[cfg(target_os = "macos")]
    {
        crate::macos::open_settings(
            main,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
        )
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = main;
        Err(PlatformError::Unsupported)
    }
}
