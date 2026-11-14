use crate::{MainThread, PlatformError};
use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

pub const MAX_TEXT_BYTES: usize = 1_048_576;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ReviewReason {
    Unsupported,
    AccessibilityRequired,
    TargetUnavailable,
    TargetChanged,
    SecurityUnknown,
    SecureField,
    NotEditable,
    WebPasteUnsupported,
    TerminalUnsafe,
    InvalidText,
    Cancelled,
    ReplacementUnavailable,
    AmbiguousNativeResult,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeliveryOutcome {
    InsertionRequested,
    Review(ReviewReason),
}

#[derive(Clone, Default)]
pub struct DeliveryCancellation(Arc<AtomicBool>);

impl DeliveryCancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::SeqCst);
    }
    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::SeqCst)
    }
}

pub struct TargetSnapshot {
    #[cfg(target_os = "macos")]
    pub(crate) native: crate::macos::NativeTarget,
    _main: MainThread,
}

impl TargetSnapshot {
    pub fn at_stop(main: &MainThread) -> Result<Self, ReviewReason> {
        #[cfg(target_os = "macos")]
        {
            Ok(Self {
                native: crate::macos::snapshot()?,
                _main: *main,
            })
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = main;
            Err(ReviewReason::Unsupported)
        }
    }

    pub fn replace_selected_text(
        self,
        text: &str,
        cancellation: &DeliveryCancellation,
    ) -> DeliveryOutcome {
        if cancellation.is_cancelled() {
            return DeliveryOutcome::Review(ReviewReason::Cancelled);
        }
        #[cfg(target_os = "macos")]
        {
            crate::macos::replace_selected(self.native, text, cancellation)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = text;
            DeliveryOutcome::Review(ReviewReason::Unsupported)
        }
    }
}

pub fn copy_from_user_action(_main: &MainThread, text: &str) -> Result<(), PlatformError> {
    if text.len() > MAX_TEXT_BYTES || text.contains('\0') {
        return Err(PlatformError::ResourceLimit);
    }
    #[cfg(target_os = "macos")]
    {
        crate::macos::copy_text(text)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err(PlatformError::Unsupported)
    }
}

pub(crate) fn text_policy(text: &str, terminal: bool, web: bool) -> Result<(), ReviewReason> {
    if text.is_empty()
        || text.len() > MAX_TEXT_BYTES
        || text
            .chars()
            .any(|character| character.is_control() && !matches!(character, '\n' | '\r' | '\t'))
    {
        return Err(ReviewReason::InvalidText);
    }
    if web {
        return Err(ReviewReason::WebPasteUnsupported);
    }
    if terminal
        && text
            .chars()
            .any(|character| character.is_control() || matches!(character, '\u{2028}' | '\u{2029}'))
    {
        return Err(ReviewReason::TerminalUnsafe);
    }
    Ok(())
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum AncestryStep {
    Root,
    Continue,
}

pub(crate) fn ancestry_policy(
    role: &str,
    subrole: Option<&str>,
) -> Result<AncestryStep, ReviewReason> {
    if role == "AXSecureTextField" || subrole == Some("AXSecureTextField") {
        return Err(ReviewReason::SecureField);
    }
    if matches!(role, "AXApplication" | "AXWindow") {
        return Ok(AncestryStep::Root);
    }
    if role.is_empty() || subrole.is_none() {
        return Err(ReviewReason::SecurityUnknown);
    }
    Ok(AncestryStep::Continue)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn web_never_uses_selected_text_fallback() {
        assert_eq!(
            text_policy("hello", false, true),
            Err(ReviewReason::WebPasteUnsupported)
        );
    }
    #[test]
    fn terminal_blocks_submission_and_controls() {
        for text in [
            "one\ntwo",
            "one\rtwo",
            "one\ttwo",
            "one\u{2028}two",
            "one\u{2029}two",
        ] {
            assert_eq!(
                text_policy(text, true, false),
                Err(ReviewReason::TerminalUnsafe)
            );
        }
        assert!(text_policy("hello", true, false).is_ok());
        assert!(text_policy("hello\0", false, false).is_err());
        assert!(text_policy("hello\u{1b}", false, false).is_err());
        assert!(text_policy("one\ntwo", false, false).is_ok());
    }
    #[test]
    fn cancellation_is_shared_and_sticky() {
        let cancellation = DeliveryCancellation::default();
        let other = cancellation.clone();
        other.cancel();
        assert!(cancellation.is_cancelled());
        assert!(text_policy(&"x".repeat(MAX_TEXT_BYTES + 1), false, false).is_err());
    }

    #[test]
    fn secure_or_missing_ancestor_metadata_fails_closed() {
        assert_eq!(
            ancestry_policy("AXTextField", None),
            Err(ReviewReason::SecurityUnknown)
        );
        assert_eq!(
            ancestry_policy("", Some("AXUnknown")),
            Err(ReviewReason::SecurityUnknown)
        );
        assert_eq!(
            ancestry_policy("AXTextField", Some("AXSecureTextField")),
            Err(ReviewReason::SecureField)
        );
        assert_eq!(
            ancestry_policy("AXSecureTextField", None),
            Err(ReviewReason::SecureField)
        );
        assert_eq!(
            ancestry_policy("AXWindow", Some("AXSecureTextField")),
            Err(ReviewReason::SecureField)
        );
        assert_eq!(ancestry_policy("AXWindow", None), Ok(AncestryStep::Root));
        assert_eq!(
            ancestry_policy("AXTextArea", Some("AXUnknown")),
            Ok(AncestryStep::Continue)
        );
    }
}
