use crate::{
    delivery::{self, DeliveryCancellation, DeliveryOutcome, ReviewReason},
    hotkey::Shortcut,
    permissions::MicrophoneStatus,
    MainThread, PlatformError,
};
use objc2::{
    class, msg_send,
    rc::Retained,
    runtime::{AnyObject, Bool},
};
use objc2_foundation::{NSString, NSURL};
use std::{
    ffi::{c_char, c_void},
    ptr,
    sync::{
        atomic::{AtomicBool, AtomicU8, Ordering},
        Arc,
    },
};

type NativeRef = *const c_void;

#[repr(C)]
#[derive(Clone, Copy, Default, PartialEq, Eq)]
struct Range {
    location: isize,
    length: isize,
}

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    pub(crate) fn AXIsProcessTrusted() -> u8;
    fn AXUIElementCreateSystemWide() -> NativeRef;
    fn AXUIElementCreateApplication(pid: i32) -> NativeRef;
    fn AXUIElementCopyAttributeValue(
        element: NativeRef,
        attribute: NativeRef,
        value: *mut NativeRef,
    ) -> i32;
    fn AXUIElementSetAttributeValue(
        element: NativeRef,
        attribute: NativeRef,
        value: NativeRef,
    ) -> i32;
    fn AXUIElementIsAttributeSettable(
        element: NativeRef,
        attribute: NativeRef,
        settable: *mut u8,
    ) -> i32;
    fn AXUIElementSetMessagingTimeout(element: NativeRef, timeout: f32) -> i32;
    fn AXUIElementGetPid(element: NativeRef, pid: *mut i32) -> i32;
    fn AXUIElementGetTypeID() -> usize;
    fn AXValueGetTypeID() -> usize;
    fn AXValueGetType(value: NativeRef) -> u32;
    fn AXValueGetValue(value: NativeRef, kind: u32, result: *mut c_void) -> u8;
}

#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFRelease(value: NativeRef);
    fn CFEqual(left: NativeRef, right: NativeRef) -> u8;
    fn CFGetTypeID(value: NativeRef) -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFStringGetCString(
        value: NativeRef,
        buffer: *mut c_char,
        capacity: isize,
        encoding: u32,
    ) -> u8;
    static kCFBooleanTrue: NativeRef;
}

#[link(name = "AVFoundation", kind = "framework")]
extern "C" {
    static AVMediaTypeAudio: *const AnyObject;
}

#[link(name = "AppKit", kind = "framework")]
extern "C" {}

extern "C" {
    pub(crate) fn pthread_main_np() -> i32;
}

pub(crate) fn microphone_status() -> MicrophoneStatus {
    let status: isize = unsafe {
        msg_send![class!(AVCaptureDevice), authorizationStatusForMediaType: AVMediaTypeAudio]
    };
    match status {
        0 => MicrophoneStatus::NotDetermined,
        1 => MicrophoneStatus::Restricted,
        2 => MicrophoneStatus::Denied,
        3 => MicrophoneStatus::Authorized,
        _ => MicrophoneStatus::Unsupported,
    }
}

pub(crate) fn request_microphone(result: Arc<AtomicU8>) {
    let completion = block2::RcBlock::new(move |granted: Bool| {
        result.store(if granted.as_bool() { 1 } else { 2 }, Ordering::Release);
    });
    unsafe {
        let _: () = msg_send![class!(AVCaptureDevice), requestAccessForMediaType: AVMediaTypeAudio, completionHandler: &*completion];
    }
}

pub(crate) fn open_settings(_main: &MainThread, address: &str) -> Result<(), PlatformError> {
    let address = NSString::from_str(address);
    let url = NSURL::URLWithString(&address).ok_or(PlatformError::NativeFailure)?;
    let workspace: Retained<AnyObject> = unsafe { msg_send![class!(NSWorkspace), sharedWorkspace] };
    let opened: Bool = unsafe { msg_send![&workspace, openURL: &*url] };
    if opened.as_bool() {
        Ok(())
    } else {
        Err(PlatformError::NativeFailure)
    }
}

pub(crate) fn copy_text(text: &str) -> Result<(), PlatformError> {
    let pasteboard: Retained<AnyObject> =
        unsafe { msg_send![class!(NSPasteboard), generalPasteboard] };
    let value = NSString::from_str(text);
    let kind = NSString::from_str("public.utf8-plain-text");
    unsafe {
        let _: isize = msg_send![&pasteboard, clearContents];
    }
    let copied: Bool = unsafe { msg_send![&pasteboard, setString: &*value, forType: &*kind] };
    if copied.as_bool() {
        Ok(())
    } else {
        Err(PlatformError::NativeFailure)
    }
}

struct OwnedRef(NativeRef);

impl OwnedRef {
    unsafe fn from_created(value: NativeRef) -> Option<Self> {
        if value.is_null() {
            None
        } else {
            Some(Self(value))
        }
    }

    fn element(value: NativeRef) -> Option<Self> {
        let owned = unsafe { Self::from_created(value)? };
        if unsafe { CFGetTypeID(value) == AXUIElementGetTypeID() } {
            if unsafe { AXUIElementSetMessagingTimeout(value, 0.05) } == 0 {
                Some(owned)
            } else {
                None
            }
        } else {
            None
        }
    }

    fn attribute(&self, name: &str) -> Option<Self> {
        let name = NSString::from_str(name);
        let mut result = ptr::null();
        let status = unsafe {
            AXUIElementCopyAttributeValue(self.0, Retained::as_ptr(&name).cast(), &mut result)
        };
        let owned = unsafe { Self::from_created(result) };
        if status == 0 {
            owned
        } else {
            None
        }
    }

    fn element_attribute(&self, name: &str) -> Option<Self> {
        let value = self.attribute(name)?;
        if unsafe { CFGetTypeID(value.0) != AXUIElementGetTypeID() } {
            return None;
        }
        if unsafe { AXUIElementSetMessagingTimeout(value.0, 0.05) } != 0 {
            return None;
        }
        Some(value)
    }

    fn string_attribute(&self, name: &str) -> Option<String> {
        let value = self.attribute(name)?;
        if unsafe { CFGetTypeID(value.0) != CFStringGetTypeID() } {
            return None;
        }
        let mut bytes = [0u8; 256];
        if unsafe {
            CFStringGetCString(
                value.0,
                bytes.as_mut_ptr().cast(),
                bytes.len() as isize,
                0x08000100,
            )
        } == 0
        {
            return None;
        }
        let length = bytes.iter().position(|byte| *byte == 0)?;
        String::from_utf8(bytes[..length].to_vec()).ok()
    }

    fn bool_attribute(&self, name: &str) -> Option<bool> {
        let value = self.attribute(name)?;
        unsafe {
            if CFGetTypeID(value.0) != CFGetTypeID(kCFBooleanTrue) {
                None
            } else {
                Some(CFEqual(value.0, kCFBooleanTrue) != 0)
            }
        }
    }

    fn settable(&self, name: &str) -> bool {
        let name = NSString::from_str(name);
        let mut result = 0;
        unsafe {
            AXUIElementIsAttributeSettable(self.0, Retained::as_ptr(&name).cast(), &mut result) == 0
                && result != 0
        }
    }

    fn pid(&self) -> Option<i32> {
        let mut pid = 0;
        if unsafe { AXUIElementGetPid(self.0, &mut pid) } == 0 && pid > 0 {
            Some(pid)
        } else {
            None
        }
    }

    fn selection(&self) -> Option<Range> {
        let value = self.attribute("AXSelectedTextRange")?;
        if unsafe { CFGetTypeID(value.0) != AXValueGetTypeID() || AXValueGetType(value.0) != 4 } {
            return None;
        }
        let mut range = Range::default();
        if unsafe { AXValueGetValue(value.0, 4, (&mut range as *mut Range).cast()) } != 0
            && range.location >= 0
            && range.length >= 0
            && range.location.checked_add(range.length).is_some()
        {
            Some(range)
        } else {
            None
        }
    }
}

impl Drop for OwnedRef {
    fn drop(&mut self) {
        unsafe {
            CFRelease(self.0);
        }
    }
}

#[derive(PartialEq, Eq)]
struct ProcessIdentity {
    pid: i32,
    started: u64,
    bundle: String,
}

fn frontmost() -> Option<ProcessIdentity> {
    let workspace: Retained<AnyObject> = unsafe { msg_send![class!(NSWorkspace), sharedWorkspace] };
    let application: Option<Retained<AnyObject>> =
        unsafe { msg_send![&workspace, frontmostApplication] };
    let application = application?;
    let pid: i32 = unsafe { msg_send![&application, processIdentifier] };
    if pid <= 0 || pid as u32 == std::process::id() {
        return None;
    }
    let terminated: Bool = unsafe { msg_send![&application, isTerminated] };
    if terminated.as_bool() {
        return None;
    }
    let date: Option<Retained<AnyObject>> = unsafe { msg_send![&application, launchDate] };
    let seconds: f64 = unsafe { msg_send![&date?, timeIntervalSince1970] };
    if !seconds.is_finite() || seconds <= 0.0 {
        return None;
    }
    let bundle: Option<Retained<NSString>> = unsafe { msg_send![&application, bundleIdentifier] };
    let bundle = bundle?.to_string();
    if bundle.is_empty() || bundle.len() > 512 {
        return None;
    }
    Some(ProcessIdentity {
        pid,
        started: seconds.to_bits(),
        bundle,
    })
}

pub(crate) struct NativeTarget {
    identity: ProcessIdentity,
    element: OwnedRef,
    role: String,
    selection: Range,
    web: bool,
    single_line_only: bool,
}

fn security(element: &OwnedRef, pid: i32) -> Result<bool, ReviewReason> {
    let started = std::time::Instant::now();
    let mut ancestors = Vec::<OwnedRef>::with_capacity(48);
    let mut current = element;
    let mut web = false;
    for _ in 0..48 {
        if started.elapsed() > std::time::Duration::from_millis(350) {
            return Err(ReviewReason::SecurityUnknown);
        }
        if current.pid() != Some(pid) {
            return Err(ReviewReason::SecurityUnknown);
        }
        let role = current
            .string_attribute("AXRole")
            .ok_or(ReviewReason::SecurityUnknown)?;
        web |= role == "AXWebArea";
        let subrole = current.string_attribute("AXSubrole");
        if delivery::ancestry_policy(&role, subrole.as_deref())? == delivery::AncestryStep::Root {
            return Ok(web);
        }
        let parent = current
            .element_attribute("AXParent")
            .ok_or(ReviewReason::SecurityUnknown)?;
        if unsafe { CFEqual(parent.0, element.0) } != 0
            || ancestors
                .iter()
                .any(|ancestor| unsafe { CFEqual(parent.0, ancestor.0) != 0 })
        {
            return Err(ReviewReason::SecurityUnknown);
        }
        ancestors.push(parent);
        current = ancestors.last().unwrap();
    }
    Err(ReviewReason::SecurityUnknown)
}

pub(crate) fn snapshot() -> Result<NativeTarget, ReviewReason> {
    if !crate::permissions::accessibility_trusted() {
        return Err(ReviewReason::AccessibilityRequired);
    }
    let identity = frontmost().ok_or(ReviewReason::TargetUnavailable)?;
    let system = OwnedRef::element(unsafe { AXUIElementCreateSystemWide() })
        .ok_or(ReviewReason::TargetUnavailable)?;
    let application = OwnedRef::element(unsafe { AXUIElementCreateApplication(identity.pid) })
        .ok_or(ReviewReason::TargetUnavailable)?;
    let global = system.element_attribute("AXFocusedUIElement");
    if global
        .as_ref()
        .is_some_and(|element| element.pid() != Some(identity.pid))
    {
        return Err(ReviewReason::TargetChanged);
    }
    let local = application.element_attribute("AXFocusedUIElement");
    let (element, role) = [global, local]
        .into_iter()
        .flatten()
        .find_map(|element| {
            let role = element.string_attribute("AXRole")?;
            if element.pid() == Some(identity.pid)
                && matches!(role.as_str(), "AXTextField" | "AXTextArea")
            {
                Some((element, role))
            } else {
                None
            }
        })
        .ok_or(ReviewReason::NotEditable)?;
    if element.bool_attribute("AXEnabled") != Some(true) || !element.settable("AXSelectedText") {
        return Err(ReviewReason::NotEditable);
    }
    let selection = element.selection().ok_or(ReviewReason::TargetUnavailable)?;
    let web = security(&element, identity.pid)?;
    let single_line_only = !matches!(
        identity.bundle.as_str(),
        "com.apple.TextEdit" | "com.apple.Notes"
    );
    if frontmost().as_ref() != Some(&identity) {
        return Err(ReviewReason::TargetChanged);
    }
    Ok(NativeTarget {
        identity,
        element,
        role,
        selection,
        web,
        single_line_only,
    })
}

pub(crate) fn replace_selected(
    target: NativeTarget,
    text: &str,
    cancellation: &DeliveryCancellation,
) -> DeliveryOutcome {
    let operation = || -> Result<(), ReviewReason> {
        delivery::text_policy(text, target.single_line_only, target.web)?;
        if cancellation.is_cancelled() {
            return Err(ReviewReason::Cancelled);
        }
        let current = snapshot()?;
        if current.identity != target.identity
            || current.role != target.role
            || current.selection != target.selection
            || current.web != target.web
            || unsafe { CFEqual(current.element.0, target.element.0) } == 0
        {
            return Err(ReviewReason::TargetChanged);
        }
        delivery::text_policy(text, current.single_line_only, current.web)?;
        let value = NSString::from_str(text);
        let attribute = NSString::from_str("AXSelectedText");
        if frontmost().as_ref() != Some(&target.identity) {
            return Err(ReviewReason::TargetChanged);
        }
        if target.element.selection() != Some(target.selection) {
            return Err(ReviewReason::TargetChanged);
        }
        let system = OwnedRef::element(unsafe { AXUIElementCreateSystemWide() })
            .ok_or(ReviewReason::TargetUnavailable)?;
        let focus = system
            .element_attribute("AXFocusedUIElement")
            .ok_or(ReviewReason::TargetUnavailable)?;
        if unsafe { CFEqual(focus.0, target.element.0) } == 0 {
            return Err(ReviewReason::TargetChanged);
        }
        if cancellation.is_cancelled() {
            return Err(ReviewReason::Cancelled);
        }
        let status = unsafe {
            AXUIElementSetAttributeValue(
                target.element.0,
                Retained::as_ptr(&attribute).cast(),
                Retained::as_ptr(&value).cast(),
            )
        };
        if status == 0 {
            Ok(())
        } else {
            Err(ReviewReason::AmbiguousNativeResult)
        }
    };
    match operation() {
        Ok(()) => DeliveryOutcome::InsertionRequested,
        Err(reason) => DeliveryOutcome::Review(reason),
    }
}

#[repr(C)]
struct EventType {
    class: u32,
    kind: u32,
}
#[repr(C)]
#[derive(Default)]
struct HotkeyId {
    signature: u32,
    id: u32,
}
type EventRef = *mut c_void;
type Handler = unsafe extern "C" fn(EventRef, EventRef, *mut c_void) -> i32;

#[link(name = "Carbon", kind = "framework")]
extern "C" {
    fn GetApplicationEventTarget() -> EventRef;
    fn InstallEventHandler(
        target: EventRef,
        handler: Handler,
        count: usize,
        events: *const EventType,
        context: *mut c_void,
        installed: *mut EventRef,
    ) -> i32;
    fn RemoveEventHandler(handler: EventRef) -> i32;
    fn RegisterEventHotKey(
        code: u32,
        modifiers: u32,
        id: HotkeyId,
        target: EventRef,
        options: u32,
        registration: *mut EventRef,
    ) -> i32;
    fn UnregisterEventHotKey(registration: EventRef) -> i32;
    fn GetEventParameter(
        event: EventRef,
        name: u32,
        kind: u32,
        actual_kind: *mut u32,
        size: usize,
        actual_size: *mut usize,
        data: *mut c_void,
    ) -> i32;
    fn GetEventKind(event: EventRef) -> u32;
}

const SIGNATURE: u32 = 0x57535052;
static HOTKEY_OWNED: AtomicBool = AtomicBool::new(false);

struct HotkeyState {
    id: u32,
    held: bool,
    pending: u64,
}

unsafe extern "C" fn hotkey_callback(
    _call: EventRef,
    event: EventRef,
    context: *mut c_void,
) -> i32 {
    if context.is_null() || event.is_null() || unsafe { pthread_main_np() } == 0 {
        return -9874;
    }
    let mut identifier = HotkeyId::default();
    let status = unsafe {
        GetEventParameter(
            event,
            0x2d2d2d2d,
            0x686b6964,
            ptr::null_mut(),
            std::mem::size_of::<HotkeyId>(),
            ptr::null_mut(),
            (&mut identifier as *mut HotkeyId).cast(),
        )
    };
    if status != 0 {
        return status;
    }
    let state = unsafe { &mut *context.cast::<HotkeyState>() };
    if identifier.signature != SIGNATURE || identifier.id != state.id {
        return -9874;
    }
    match unsafe { GetEventKind(event) } {
        5 if !state.held => {
            state.held = true;
            state.pending = state.pending.saturating_add(1);
        }
        6 => state.held = false,
        _ => {}
    }
    0
}

pub(crate) struct NativeHotkey {
    state: Box<HotkeyState>,
    handler: EventRef,
    registration: EventRef,
    orphan: EventRef,
    shortcut: Option<Shortcut>,
    poisoned: bool,
}

impl NativeHotkey {
    pub(crate) fn new(shortcut: Shortcut) -> Result<Self, PlatformError> {
        if HOTKEY_OWNED.swap(true, Ordering::AcqRel) {
            return Err(PlatformError::ShortcutUnavailable);
        }
        let mut owner = Self {
            state: Box::new(HotkeyState {
                id: 0,
                held: false,
                pending: 0,
            }),
            handler: ptr::null_mut(),
            registration: ptr::null_mut(),
            orphan: ptr::null_mut(),
            shortcut: None,
            poisoned: false,
        };
        let events = [
            EventType {
                class: 0x6b657962,
                kind: 5,
            },
            EventType {
                class: 0x6b657962,
                kind: 6,
            },
        ];
        let status = unsafe {
            InstallEventHandler(
                GetApplicationEventTarget(),
                hotkey_callback,
                2,
                events.as_ptr(),
                (&mut *owner.state as *mut HotkeyState).cast(),
                &mut owner.handler,
            )
        };
        if status != 0 || owner.handler.is_null() {
            return Err(PlatformError::NativeFailure);
        }
        owner.replace(shortcut)?;
        Ok(owner)
    }

    pub(crate) fn replace(&mut self, shortcut: Shortcut) -> Result<(), PlatformError> {
        if self.poisoned {
            return Err(PlatformError::NativeFailure);
        }
        if self.shortcut == Some(shortcut) {
            return Ok(());
        }
        let id = self
            .state
            .id
            .checked_add(1)
            .ok_or(PlatformError::ResourceLimit)?;
        let mut replacement = ptr::null_mut();
        let (key_code, modifiers) = shortcut.native_parts();
        let status = unsafe {
            RegisterEventHotKey(
                key_code,
                modifiers,
                HotkeyId {
                    signature: SIGNATURE,
                    id,
                },
                GetApplicationEventTarget(),
                0,
                &mut replacement,
            )
        };
        if status != 0 || replacement.is_null() {
            return Err(PlatformError::ShortcutUnavailable);
        }
        if !self.registration.is_null() && unsafe { UnregisterEventHotKey(self.registration) } != 0
        {
            if unsafe { UnregisterEventHotKey(replacement) } != 0 {
                self.orphan = replacement;
            }
            self.poisoned = true;
            return Err(PlatformError::NativeFailure);
        }
        self.registration = replacement;
        self.state.id = id;
        self.state.held = false;
        self.state.pending = 0;
        self.shortcut = Some(shortcut);
        Ok(())
    }

    pub(crate) fn take_pressed(&mut self) -> bool {
        if self.state.pending == 0 {
            false
        } else {
            self.state.pending -= 1;
            true
        }
    }
}

impl Drop for NativeHotkey {
    fn drop(&mut self) {
        self.state.id = 0;
        unsafe {
            if !self.registration.is_null() {
                UnregisterEventHotKey(self.registration);
            }
            if !self.orphan.is_null() {
                UnregisterEventHotKey(self.orphan);
            }
            if !self.handler.is_null() && RemoveEventHandler(self.handler) != 0 {
                let state = std::mem::replace(
                    &mut self.state,
                    Box::new(HotkeyState {
                        id: 0,
                        held: false,
                        pending: 0,
                    }),
                );
                let _ = Box::into_raw(state);
                return;
            }
        }
        HOTKEY_OWNED.store(false, Ordering::Release);
    }
}
