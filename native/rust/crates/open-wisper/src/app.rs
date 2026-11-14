use crate::{policy, storage};
use objc2::rc::{autoreleasepool, Allocated, Retained};
use objc2::runtime::{AnyObject, Bool};
use objc2::{class, define_class, msg_send, sel, MainThreadOnly};
use objc2_app_kit::{NSButton, NSPanel};
use objc2_foundation::{
    MainThreadMarker, NSObject, NSObjectProtocol, NSPoint, NSRect, NSSize, NSString,
};
use std::cell::RefCell;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};
use wisper_core::{
    Cancellation, EngineManifest, Generation, Model, Phase, SessionCoordinator, SessionWorkspace,
    Settings, SettingsStore, ValidatedEngineProfile,
};
use wisper_platform::audio::{CaptureSession, CaptureStatus};
use wisper_platform::delivery::{
    self, DeliveryCancellation, DeliveryOutcome, ReviewReason, TargetSnapshot,
};
use wisper_platform::hotkey::GlobalHotkey;
use wisper_platform::permissions::{self, MicrophoneRequest, MicrophoneStatus};
use wisper_platform::MainThread;

thread_local! {
    static STATE: RefCell<Option<App>> = const { RefCell::new(None) };
}

define_class!(
    #[unsafe(super = NSObject)]
    #[thread_kind = MainThreadOnly]
    struct Delegate;

    unsafe impl NSObjectProtocol for Delegate {}

    impl Delegate {
        #[unsafe(method(action:))]
        fn action(&self, sender: &AnyObject) {
            let tag: isize = unsafe { msg_send![sender, tag] };
            STATE.with(|state| {
                if let Some(app) = state.borrow_mut().as_mut() {
                    app.action(tag);
                }
            });
        }

        #[unsafe(method(tick:))]
        fn tick(&self, _timer: &AnyObject) {
            autoreleasepool(|_| STATE.with(|state| {
                if let Some(app) = state.borrow_mut().as_mut() {
                    app.tick();
                }
            }));
        }

        #[unsafe(method(applicationShouldTerminate:))]
        fn should_terminate(&self, _sender: &AnyObject) -> usize {
            STATE.with(|state| {
                if let Some(app) = state.borrow_mut().as_mut() {
                    app.action(9);
                }
            });
            0
        }
    }
);

define_class!(
    #[unsafe(super = NSPanel)]
    #[thread_kind = MainThreadOnly]
    struct PillPanel;

    impl PillPanel {
        #[unsafe(method(canBecomeKeyWindow))]
        fn can_become_key(&self) -> Bool { Bool::NO }

        #[unsafe(method(canBecomeMainWindow))]
        fn can_become_main(&self) -> Bool { Bool::NO }
    }
);

define_class!(
    #[unsafe(super = NSButton)]
    #[thread_kind = MainThreadOnly]
    struct FirstMouseButton;

    impl FirstMouseButton {
        #[unsafe(method(acceptsFirstMouse:))]
        fn accepts_first_mouse(&self, _event: Option<&AnyObject>) -> Bool { Bool::YES }
    }
);

enum WorkerResult {
    Profile(Result<Box<ValidatedEngineProfile>, String>),
    Transcript(Result<String, String>),
}

struct Completion {
    generation: Generation,
    result: WorkerResult,
}

#[derive(Clone, Copy, PartialEq)]
enum Page {
    Ready,
    Review,
    Settings,
}

struct App {
    main: MainThread,
    native: Retained<AnyObject>,
    delegate: Retained<Delegate>,
    _lock: storage::InstanceLock,
    _status_item: Retained<AnyObject>,
    timer: Retained<AnyObject>,
    window: Retained<AnyObject>,
    pill: Retained<PillPanel>,
    pill_status: Retained<AnyObject>,
    pill_stop: Retained<AnyObject>,
    pill_cancel: Retained<AnyObject>,
    content: Option<Retained<AnyObject>>,
    message_view: Option<Retained<AnyObject>>,
    model_picker: Option<Retained<AnyObject>>,
    shortcut_picker: Option<Retained<AnyObject>>,
    profile_field: Option<Retained<AnyObject>>,
    insertion_button: Option<Retained<AnyObject>>,
    record_button: Option<Retained<AnyObject>>,
    shortcut_names: Vec<String>,
    page: Page,
    coordinator: SessionCoordinator,
    settings: Settings,
    settings_invalid: bool,
    store: SettingsStore,
    sessions: PathBuf,
    resources: PathBuf,
    hotkey: Option<GlobalHotkey>,
    capture: Option<CaptureSession>,
    permission: Option<(Generation, MicrophoneRequest)>,
    profile: Option<ValidatedEngineProfile>,
    target: Option<Result<TargetSnapshot, ReviewReason>>,
    cancellation: Cancellation,
    delivery_cancel: DeliveryCancellation,
    worker: Option<JoinHandle<()>>,
    sender: Sender<Completion>,
    receiver: Receiver<Completion>,
    transcript: String,
    message: String,
    feedback_until: Option<Instant>,
    recording_since: Option<Instant>,
    quitting: bool,
}

pub fn run() -> Result<(), String> {
    let main = MainThread::acquire().map_err(|error| error.to_string())?;
    let home = PathBuf::from(std::env::var_os("HOME").ok_or("HOME is unavailable.")?);
    let support = home.join("Library/Application Support");
    for parent in [home.clone(), home.join("Library"), support.clone()] {
        let metadata = std::fs::symlink_metadata(&parent)
            .map_err(|_| "Application Support is unavailable.")?;
        use std::os::unix::fs::MetadataExt;
        if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err(
                "Application Support must be an owned directory, not a symbolic link.".into(),
            );
        }
    }
    let root = support.join("OpenWisper-Rust");
    let instance = storage::InstanceLock::acquire(&root).map_err(|error| error.to_string())?;
    let sessions = root.join("sessions");
    storage::private_directory(&sessions).map_err(|error| error.to_string())?;
    let store = SettingsStore::new(SettingsStore::default_path(&home));
    let (settings, settings_invalid, mut message) = match store.load() {
        Ok(settings) => (settings, false, "Ready. Local dictation, no account.".to_owned()),
        Err(_) => (Settings::default(), true, "Settings are invalid. Recording is disabled. Review and explicitly save Settings to replace them.".to_owned()),
    };
    if std::fs::read_dir(&sessions)
        .map_err(|error| error.to_string())?
        .next()
        .is_some()
    {
        message.push_str(" Interrupted-session files remain in the private sessions folder. They are not read or automatically deleted; inspect and remove them manually.");
    }
    let executable = std::env::current_exe().map_err(|error| error.to_string())?;
    let resources = executable
        .parent()
        .and_then(|path| path.parent())
        .ok_or("Missing executable directory.")?
        .join("Resources");
    let hotkey = if settings_invalid {
        None
    } else {
        match policy::shortcut_name(&settings.shortcut)
            .and_then(|name| {
                name.parse()
                    .map_err(|error: wisper_platform::PlatformError| error.to_string())
            })
            .and_then(|shortcut| {
                GlobalHotkey::new(&main, shortcut).map_err(|error| error.to_string())
            }) {
            Ok(hotkey) => Some(hotkey),
            Err(_) => {
                message.push_str(" Shortcut unavailable. Use the menu or choose a different shortcut in Settings.");
                None
            }
        }
    };
    let marker = MainThreadMarker::new().ok_or("AppKit requires the main thread.")?;
    autoreleasepool(|_| unsafe {
        let native: Retained<AnyObject> = msg_send![class!(NSApplication), sharedApplication];
        let _: Bool = msg_send![&native, setActivationPolicy: 1isize];
        let delegate: Retained<Delegate> = msg_send![Delegate::alloc(marker), init];
        let _: () = msg_send![&native, setDelegate: &*delegate];
        let menu = make_menu(&delegate);
        let _: () = msg_send![&native, setMainMenu: &*menu];
        let status_bar: Retained<AnyObject> = msg_send![class!(NSStatusBar), systemStatusBar];
        let status_item: Retained<AnyObject> =
            msg_send![&status_bar, statusItemWithLength: -1.0f64];
        let status_button: Retained<AnyObject> = msg_send![&status_item, button];
        let _: () = msg_send![&status_button, setTitle: &*NSString::from_str("◉")];
        let _: () = msg_send![&status_button, setAccessibilityLabel: &*NSString::from_str("Open Wisper Rust")];
        let status_menu = action_menu(&delegate);
        let _: () = msg_send![&status_item, setMenu: &*status_menu];
        let window: Allocated<AnyObject> = msg_send![class!(NSWindow), alloc];
        let window: Retained<AnyObject> = msg_send![window, initWithContentRect: rect(0.0, 0.0, 360.0, 480.0), styleMask: 15usize, backing: 2usize, defer: Bool::NO];
        let _: () = msg_send![&window, setReleasedWhenClosed: Bool::NO];
        let _: () = msg_send![&window, setTitle: &*NSString::from_str("Open Wisper Rust")];
        let _: () = msg_send![&window, setContentMinSize: NSSize::new(340.0, 420.0)];
        let _: () = msg_send![&window, setBackgroundColor: &*color(1.0, 0.973, 0.933)];
        let _: () = msg_send![&window, center];
        let pill: Retained<PillPanel> = msg_send![PillPanel::alloc(marker), initWithContentRect: rect(0.0, 0.0, 340.0, 52.0), styleMask: 128usize, backing: 2usize, defer: Bool::NO];
        let _: () = msg_send![&pill, setReleasedWhenClosed: Bool::NO];
        let _: () = msg_send![&pill, setOpaque: Bool::NO];
        let clear: Retained<AnyObject> = msg_send![class!(NSColor), clearColor];
        let _: () = msg_send![&pill, setBackgroundColor: &*clear];
        let _: () = msg_send![&pill, setHasShadow: Bool::YES];
        let _: () = msg_send![&pill, setLevel: 25isize];
        let _: () = msg_send![&pill, setCollectionBehavior: (1usize | 16 | 256)];
        let _: () = msg_send![&pill, setHidesOnDeactivate: Bool::NO];
        let pill_content: Retained<AnyObject> = msg_send![&pill, contentView];
        rounded(&pill_content, 26.0, &color(0.129, 0.247, 0.251));
        let pill_status = button(
            &pill_content,
            &delegate,
            "Status",
            10,
            rect(8.0, 8.0, 190.0, 36.0),
            true,
        );
        let pill_stop = button(
            &pill_content,
            &delegate,
            "Stop",
            4,
            rect(202.0, 8.0, 60.0, 36.0),
            true,
        );
        let pill_cancel = button(
            &pill_content,
            &delegate,
            "Cancel",
            5,
            rect(264.0, 8.0, 68.0, 36.0),
            true,
        );
        let timer: Retained<AnyObject> = msg_send![class!(NSTimer), timerWithTimeInterval: 0.04f64, target: &*delegate, selector: sel!(tick:), userInfo: std::ptr::null::<AnyObject>(), repeats: Bool::YES];
        let run_loop: Retained<AnyObject> = msg_send![class!(NSRunLoop), mainRunLoop];
        let _: () = msg_send![&run_loop, addTimer: &*timer, forMode: &*NSString::from_str("kCFRunLoopCommonModes")];
        let (sender, receiver) = mpsc::channel();
        let app = App {
            main,
            native: native.clone(),
            delegate,
            _lock: instance,
            _status_item: status_item,
            timer,
            window,
            pill,
            pill_status,
            pill_stop,
            pill_cancel,
            content: None,
            message_view: None,
            model_picker: None,
            shortcut_picker: None,
            profile_field: None,
            insertion_button: None,
            record_button: None,
            shortcut_names: Vec::new(),
            page: Page::Ready,
            coordinator: SessionCoordinator::new(),
            settings,
            settings_invalid,
            store,
            sessions,
            resources,
            hotkey,
            capture: None,
            permission: None,
            profile: None,
            target: None,
            cancellation: Cancellation::new(),
            delivery_cancel: DeliveryCancellation::default(),
            worker: None,
            sender,
            receiver,
            transcript: String::new(),
            message,
            feedback_until: None,
            recording_since: None,
            quitting: false,
        };
        STATE.with(|state| *state.borrow_mut() = Some(app));
        let _: () = msg_send![&native, run];
        STATE.with(|state| {
            if let Some(mut app) = state.borrow_mut().take() {
                app.cancel();
                let _: () = msg_send![&app.timer, invalidate];
                if let Some(worker) = app.worker.take() {
                    let _ = worker.join();
                }
            }
        });
        Ok(())
    })
}

impl App {
    fn action(&mut self, tag: isize) {
        if self.quitting {
            return;
        }
        match tag {
            1 => self.open(Page::Ready),
            2 => self.open(Page::Review),
            3 => self.open(Page::Settings),
            4 => self.toggle(),
            5 => {
                self.cancel();
                self.message = "Cancelled".into();
                self.feedback_until = Some(Instant::now() + Duration::from_millis(1200));
                self.refresh();
            }
            6 => {
                if !self.transcript.is_empty() {
                    self.message =
                        match delivery::copy_from_user_action(&self.main, &self.transcript) {
                            Ok(()) => {
                                "Copied explicitly. Clipboard now contains the transcript.".into()
                            }
                            Err(_) => "Copy failed. Select the text and use Edit → Copy.".into(),
                        };
                    self.refresh();
                }
            }
            7 => {
                if self.worker.is_none()
                    && !matches!(
                        self.coordinator.phase(),
                        Phase::Starting | Phase::Recording | Phase::Stopping | Phase::Transcribing
                    )
                {
                    self.cancel();
                    self.message = "Ready. Transcript dismissed; no history retained.".into();
                    self.feedback_until = None;
                    self.page = Page::Ready;
                    unsafe {
                        let _: () = msg_send![&self.pill, orderOut: std::ptr::null::<AnyObject>()];
                    }
                    self.render();
                }
            }
            8 => self.save_settings(),
            9 => {
                self.quitting = true;
                self.cancel();
                self.message = "Quitting — waiting for worker cleanup…".into();
                self.refresh();
            }
            10 => self.open(if !self.transcript.is_empty() {
                Page::Review
            } else if self.coordinator.phase() == Phase::Idle {
                Page::Settings
            } else {
                Page::Ready
            }),
            11 | 12 => {
                let opened = if tag == 11 {
                    permissions::open_accessibility_settings_from_user_action(&self.main)
                } else {
                    permissions::open_microphone_settings_from_user_action(&self.main)
                };
                if opened.is_err() {
                    self.message = "Could not open permission settings.".into();
                    self.refresh();
                }
            }
            _ => (),
        }
    }

    fn toggle(&mut self) {
        if self.coordinator.phase() == Phase::Starting {
            self.action(5);
            return;
        }
        if self.coordinator.phase() == Phase::Recording {
            self.stop();
            return;
        }
        if self.worker.is_some() || !matches!(self.coordinator.phase(), Phase::Idle | Phase::Ready)
        {
            return;
        }
        if self.settings_invalid {
            self.fail(
                "Settings are invalid. Open Settings and explicitly save a valid configuration.",
            );
            return;
        }
        let path = match policy::profile_path(&self.settings, &self.resources) {
            Ok(path) => path,
            Err(error) => {
                self.fail(&error);
                return;
            }
        };
        self.cancel();
        self.transcript.clear();
        let generation = self.coordinator.start();
        self.cancellation = Cancellation::new();
        self.delivery_cancel = DeliveryCancellation::default();
        self.message = "Checking local model…".into();
        self.feedback_until = None;
        let cancellation = self.cancellation.clone();
        self.spawn(generation, move || WorkerResult::Profile(EngineManifest::load_validated(&path, &cancellation).map(Box::new).map_err(|_| "Selected engine profile failed validation. Check Settings; no recording started.".into())));
        self.refresh();
    }

    fn spawn(
        &mut self,
        generation: Generation,
        work: impl FnOnce() -> WorkerResult + Send + 'static,
    ) {
        if self.worker.is_some() {
            self.fail("Previous worker is still cleaning up.");
            return;
        }
        let sender = self.sender.clone();
        match std::thread::Builder::new()
            .name("wisper-offline-worker".into())
            .spawn(move || {
                let result = work();
                let _ = sender.send(Completion { generation, result });
            }) {
            Ok(worker) => self.worker = Some(worker),
            Err(_) => self.fail("Could not create the offline worker."),
        }
    }

    fn request_capture(&mut self, generation: Generation) {
        if self.coordinator.generation() != Some(generation) {
            return;
        }
        match permissions::microphone_status() {
            MicrophoneStatus::Authorized => self.start_capture(generation),
            MicrophoneStatus::NotDetermined => {
                match MicrophoneRequest::request_from_user_action(&self.main) {
                    Ok(request) => {
                        self.permission = Some((generation, request));
                        self.message = "Waiting for microphone permission…".into();
                        self.refresh();
                    }
                    Err(_) => {
                        self.fail("Microphone request failed. Open Settings to check permissions.")
                    }
                }
            }
            _ => self.fail("Microphone permission is unavailable. Open Settings to enable it."),
        }
    }

    fn start_capture(&mut self, generation: Generation) {
        if self.coordinator.generation() != Some(generation) {
            return;
        }
        match CaptureSession::start() {
            Ok(capture) => {
                if self.coordinator.recording_started(generation) {
                    self.capture = Some(capture);
                    self.recording_since = Some(Instant::now());
                    self.message = "Listening. Stop to transcribe locally.".into();
                    self.refresh();
                } else {
                    let _ = capture.cancel();
                }
            }
            Err(_) => self
                .fail("Could not start microphone capture. Check the input device and permission."),
        }
    }

    fn stop(&mut self) {
        if self.coordinator.phase() != Phase::Recording || self.worker.is_some() {
            return;
        }
        self.target = Some(TargetSnapshot::at_stop(&self.main));
        let Some(generation) = self.coordinator.stop() else {
            return;
        };
        let Some(capture) = self.capture.take() else {
            self.fail("Capture session is unavailable.");
            return;
        };
        let audio = match capture.stop() {
            Ok(audio) => audio,
            Err(_) => {
                self.fail("Capture failed; partial audio was discarded. Try another input device.");
                return;
            }
        };
        self.recording_since = None;
        let Some(profile) = self.profile.take() else {
            self.fail("Validated engine profile is unavailable.");
            return;
        };
        if !self.coordinator.audio_ready(generation) {
            return;
        }
        self.message = "Transcribing locally…".into();
        let root = self.sessions.clone();
        let cancellation = self.cancellation.clone();
        let timeout = Duration::from_secs(self.settings.worker_timeout_seconds.into());
        self.spawn(generation, move || {
            let result = (|| {
                if cancellation.is_cancelled() {
                    return Err("Cancelled".into());
                }
                let mut workspace = SessionWorkspace::create(&root)
                    .map_err(|_| "Could not create a private audio workspace.".to_owned())?;
                let result = (|| {
                    workspace
                        .write_pcm16(&audio.samples)
                        .map_err(|_| "Could not write private audio.".to_owned())?;
                    wisper_core::transcribe(&profile, &workspace, &cancellation, timeout)
                        .map(|transcript| transcript.text)
                        .map_err(|error| format!("Local transcription failed ({error:?})."))
                })();
                storage::finish_workspace(&mut workspace, result)
            })();
            WorkerResult::Transcript(result)
        });
        self.refresh();
    }

    fn cancel(&mut self) {
        self.delivery_cancel.cancel();
        self.coordinator.cancel();
        self.target = None;
        self.cancellation.cancel();
        if let Some((_, request)) = self.permission.take() {
            request.cancel();
        }
        if let Some(capture) = self.capture.take() {
            let _ = capture.cancel();
        }
        self.profile = None;
        self.recording_since = None;
        self.transcript.clear();
    }

    fn fail(&mut self, message: &str) {
        self.cancel();
        self.message = message.into();
        self.feedback_until = None;
        self.refresh();
    }

    fn tick(&mut self) {
        if self.worker.as_ref().is_some_and(JoinHandle::is_finished) {
            let joined = self.worker.take().expect("worker exists").join();
            match self.receiver.try_recv() {
                Ok(completion)
                    if self.coordinator.generation() == Some(completion.generation)
                        && !self.quitting =>
                {
                    match completion.result {
                        WorkerResult::Profile(Ok(profile)) => {
                            self.profile = Some(*profile);
                            self.request_capture(completion.generation);
                        }
                        WorkerResult::Transcript(Ok(text)) => {
                            self.complete(completion.generation, text)
                        }
                        WorkerResult::Profile(Err(error))
                        | WorkerResult::Transcript(Err(error)) => self.fail(&error),
                    }
                }
                Ok(_) => (),
                Err(_) if joined.is_err() && !self.quitting => {
                    self.fail("Offline worker failed unexpectedly; no delivery was attempted.")
                }
                Err(_) => (),
            }
        }
        if self.quitting {
            if self.worker.is_none() {
                unsafe {
                    let _: () = msg_send![&self.native, stop: std::ptr::null::<AnyObject>()];
                }
            }
            return;
        }
        if let Some((generation, allowed)) = self
            .permission
            .as_ref()
            .and_then(|(generation, request)| request.poll().map(|allowed| (*generation, allowed)))
        {
            self.permission = None;
            if allowed {
                self.start_capture(generation);
            } else {
                self.fail("Microphone access was denied. Open Settings to enable it.");
            }
        }
        if let Some(capture) = &self.capture {
            match capture.status() {
                CaptureStatus::Recording
                    if self.recording_since.is_some_and(|start| {
                        start.elapsed().as_secs() >= self.settings.maximum_duration_seconds.into()
                    }) =>
                {
                    self.stop()
                }
                CaptureStatus::DurationLimit => self.stop(),
                CaptureStatus::Failed(_) => {
                    self.fail("Audio capture failed; partial audio was discarded.")
                }
                _ => (),
            }
        }
        let pressed = self
            .hotkey
            .as_mut()
            .is_some_and(|hotkey| hotkey.take_pressed());
        if pressed {
            self.toggle();
        }
        if self
            .feedback_until
            .is_some_and(|deadline| Instant::now() >= deadline)
        {
            self.feedback_until = None;
            unsafe {
                let _: () = msg_send![&self.pill, orderOut: std::ptr::null::<AnyObject>()];
            }
        }
        if self.coordinator.phase() == Phase::Recording {
            let seconds = self
                .recording_since
                .map_or(0, |start| start.elapsed().as_secs());
            unsafe {
                let _: () = msg_send![&self.pill_status, setTitle: &*NSString::from_str(&format!("Listening  {}:{:02}", seconds / 60, seconds % 60))];
            }
        }
    }

    fn complete(&mut self, generation: Generation, text: String) {
        if !self.coordinator.transcription_ready(generation) {
            return;
        }
        self.transcript = text;
        self.message = "Ready for Review / Copy. Automatic insertion is off.".into();
        if self.settings.automatic_insertion && self.coordinator.authorize_delivery(generation) {
            let outcome = match self.target.take() {
                Some(Ok(target)) => {
                    target.replace_selected_text(&self.transcript, &self.delivery_cancel)
                }
                Some(Err(reason)) => DeliveryOutcome::Review(reason),
                None => DeliveryOutcome::Review(ReviewReason::TargetUnavailable),
            };
            match outcome {
                DeliveryOutcome::InsertionRequested => {
                    self.message = "Insertion requested — not independently verified. Transcript remains available in Review.".into();
                    self.feedback_until = Some(Instant::now() + Duration::from_millis(1800));
                }
                DeliveryOutcome::Review(reason) => {
                    self.message = format!(
                        "Review / Copy required ({reason:?}). No paste or retry was attempted."
                    );
                    self.feedback_until = None;
                }
            }
        } else {
            self.target = None;
            self.feedback_until = None;
        }
        if self.page != Page::Settings {
            self.page = Page::Review;
            self.render();
        }
        self.refresh();
    }

    fn save_settings(&mut self) {
        if self.worker.is_some() || !matches!(self.coordinator.phase(), Phase::Idle | Phase::Ready)
        {
            self.message = "Stop or cancel the current session before changing Settings.".into();
            self.refresh();
            return;
        }
        let Some(picker) = &self.model_picker else {
            return;
        };
        let mut proposed = self.settings.clone();
        unsafe {
            let index: isize = msg_send![picker, indexOfSelectedItem];
            proposed.model = match index {
                0 => Model::Base,
                1 => Model::Tiny,
                2 => Model::Small,
                _ => Model::Custom,
            };
            let field = self.profile_field.as_ref().expect("settings field");
            let path: Retained<NSString> = msg_send![field, stringValue];
            proposed.engine_profile_path = path.to_string();
            let insertion: isize = msg_send![
                self.insertion_button.as_ref().expect("settings toggle"),
                state
            ];
            proposed.automatic_insertion = insertion == 1;
            let selection: isize = msg_send![
                self.shortcut_picker.as_ref().expect("shortcut picker"),
                indexOfSelectedItem
            ];
            let Some(name) = usize::try_from(selection)
                .ok()
                .and_then(|index| self.shortcut_names.get(index))
            else {
                return;
            };
            if let Some((_, key_code, modifiers)) =
                policy::SHORTCUTS.iter().find(|(title, _, _)| title == name)
            {
                proposed.shortcut = wisper_core::Shortcut {
                    key_code: *key_code,
                    modifiers: *modifiers,
                };
            }
        }
        if proposed.validate().is_err() {
            self.message = "Invalid settings. Custom profiles need an absolute manifest path. Nothing was saved.".into();
            self.refresh();
            return;
        }
        let name = match policy::shortcut_name(&proposed.shortcut) {
            Ok(name) => name,
            Err(error) => {
                self.message = error;
                self.refresh();
                return;
            }
        };
        let shortcut = match name.parse() {
            Ok(shortcut) => shortcut,
            Err(_) => {
                self.message = "Invalid shortcut. Nothing was saved.".into();
                self.refresh();
                return;
            }
        };
        let had_hotkey = self.hotkey.is_some();
        let registered = match &mut self.hotkey {
            Some(hotkey) => hotkey.replace(shortcut),
            None => {
                GlobalHotkey::new(&self.main, shortcut).map(|hotkey| self.hotkey = Some(hotkey))
            }
        };
        if registered.is_err() {
            self.message =
                "Shortcut is already in use. Previous shortcut and settings retained.".into();
            self.refresh();
            return;
        }
        if self.store.save(&proposed).is_err() {
            let restored = had_hotkey
                && policy::shortcut_name(&self.settings.shortcut)
                    .ok()
                    .and_then(|name| name.parse().ok())
                    .is_some_and(|previous| {
                        self.hotkey
                            .as_mut()
                            .expect("registered hotkey")
                            .replace(previous)
                            .is_ok()
                    });
            if !restored {
                self.hotkey = None;
            }
            self.message = if restored {
                "Settings could not be saved. Previous shortcut restored."
            } else {
                "Settings could not be saved. Shortcut disabled; use the menu."
            }
            .into();
            self.refresh();
            return;
        }
        self.settings = proposed;
        self.settings_invalid = false;
        self.message = "Settings saved. Microphone is requested only on Record. Accessibility is needed for insertion; browsers use Review / Copy.".into();
        self.refresh();
    }

    fn open(&mut self, page: Page) {
        self.page = page;
        self.render();
        unsafe {
            let _: () =
                msg_send![&self.window, makeKeyAndOrderFront: std::ptr::null::<AnyObject>()];
            let _: () = msg_send![&self.native, activateIgnoringOtherApps: Bool::YES];
        }
    }

    fn refresh(&mut self) {
        unsafe {
            if let Some(view) = &self.message_view {
                let _: () = msg_send![view, setStringValue: &*NSString::from_str(&self.message)];
            }
            let phase = self.coordinator.phase();
            if let Some(button) = &self.record_button {
                let _: () = msg_send![button, setTitle: &*NSString::from_str(if phase == Phase::Recording { "Stop" } else { "Record" })];
                let _: () = msg_send![button, setEnabled: Bool::new(!self.quitting && (phase == Phase::Recording || (matches!(phase, Phase::Idle | Phase::Ready) && self.worker.is_none())))];
            }
            let title = match phase {
                Phase::Starting => "Preparing…",
                Phase::Recording => "Listening…",
                Phase::Stopping | Phase::Transcribing => "Transcribing…",
                Phase::Ready if self.feedback_until.is_some() => "Insertion requested",
                Phase::Ready => "Review / Copy",
                Phase::Idle if self.feedback_until.is_some() => "Cancelled",
                Phase::Idle => "Setup / Status",
            };
            let _: () = msg_send![&self.pill_status, setTitle: &*NSString::from_str(title)];
            let _: () =
                msg_send![&self.pill_stop, setEnabled: Bool::new(phase == Phase::Recording)];
            let _: () = msg_send![&self.pill_cancel, setEnabled: Bool::new(phase != Phase::Idle || self.worker.is_some())];
            let screen: Option<Retained<AnyObject>> = msg_send![class!(NSScreen), mainScreen];
            if let Some(screen) = screen {
                let frame: NSRect = msg_send![&screen, visibleFrame];
                let width = 340.0f64.min((frame.size.width - 16.0).max(1.0));
                let origin = NSPoint::new(
                    frame.origin.x + (frame.size.width - width) / 2.0,
                    frame.origin.y + 28.0,
                );
                let _: () = msg_send![&self.pill, setFrameOrigin: origin];
                let _: () = msg_send![&self.pill, setContentSize: NSSize::new(width, 52.0)];
            }
            let _: () = msg_send![&self.pill, orderFrontRegardless];
        }
    }

    fn render(&mut self) {
        unsafe {
            let scroll: Allocated<AnyObject> = msg_send![class!(NSScrollView), alloc];
            let scroll: Retained<AnyObject> =
                msg_send![scroll, initWithFrame: rect(0.0, 0.0, 360.0, 480.0)];
            let _: () = msg_send![&scroll, setHasVerticalScroller: Bool::YES];
            let _: () = msg_send![&scroll, setDrawsBackground: Bool::NO];
            let _: () = msg_send![&scroll, setAutoresizingMask: 18usize];
            let height = if self.page == Page::Settings {
                660.0
            } else {
                440.0
            };
            let content: Allocated<AnyObject> = msg_send![class!(NSView), alloc];
            let content: Retained<AnyObject> =
                msg_send![content, initWithFrame: rect(0.0, 0.0, 340.0, height)];
            let _: () = msg_send![&content, setAutoresizingMask: 2usize];
            let _: () = msg_send![&scroll, setDocumentView: &*content];
            let _: () = msg_send![&self.window, setContentView: &*scroll];
            for (title, tag, position) in [
                ("Ready", 1, 16.0),
                ("Review", 2, 116.0),
                ("Settings", 3, 216.0),
            ] {
                button(
                    &content,
                    &self.delegate,
                    title,
                    tag,
                    rect(position, height - 42.0, 94.0, 28.0),
                    false,
                );
            }
            let heading = match self.page {
                Page::Ready => "Your voice, locally.",
                Page::Review => "Review your words",
                Page::Settings => "Make it yours",
            };
            label(
                &content,
                heading,
                rect(20.0, height - 88.0, 300.0, 32.0),
                23.0,
            );
            self.message_view = Some(label(
                &content,
                &self.message,
                rect(20.0, height - 188.0, 300.0, 88.0),
                13.0,
            ));
            self.model_picker = None;
            self.profile_field = None;
            self.shortcut_picker = None;
            self.insertion_button = None;
            self.record_button = None;
            match self.page {
                Page::Ready => {
                    let title = if self.coordinator.phase() == Phase::Recording {
                        "Stop"
                    } else {
                        "Record"
                    };
                    let primary = button(
                        &content,
                        &self.delegate,
                        title,
                        4,
                        rect(120.0, 112.0, 100.0, 100.0),
                        false,
                    );
                    let _: () = msg_send![&primary, setBezelStyle: 7usize];
                    let _: () = msg_send![&primary, setBordered: Bool::NO];
                    rounded(&primary, 50.0, &color(0.157, 0.357, 0.349));
                    let _: () =
                        msg_send![&primary, setContentTintColor: &*color(1.0, 0.973, 0.933)];
                    self.record_button = Some(primary);
                    label(
                        &content,
                        "For cursor insertion, use the shortcut or bottom pill.\nStopping here uses Review / Copy.",
                        rect(20.0, 36.0, 300.0, 55.0),
                        13.0,
                    );
                }
                Page::Review => {
                    let transcript_scroll: Allocated<AnyObject> =
                        msg_send![class!(NSScrollView), alloc];
                    let transcript_scroll: Retained<AnyObject> =
                        msg_send![transcript_scroll, initWithFrame: rect(20.0, 84.0, 300.0, 164.0)];
                    let _: () = msg_send![&transcript_scroll, setHasVerticalScroller: Bool::YES];
                    let text: Allocated<AnyObject> = msg_send![class!(NSTextView), alloc];
                    let text: Retained<AnyObject> =
                        msg_send![text, initWithFrame: rect(0.0, 0.0, 280.0, 164.0)];
                    let _: () = msg_send![&text, setString: &*NSString::from_str(&self.transcript)];
                    let _: () = msg_send![&text, setEditable: Bool::NO];
                    let _: () = msg_send![&text, setSelectable: Bool::YES];
                    let _: () = msg_send![&text, setVerticallyResizable: Bool::YES];
                    let _: () = msg_send![&text, setMaxSize: NSSize::new(280.0, 1_000_000.0)];
                    let _: () = msg_send![&text, setFont: &*font(15.0)];
                    let _: () = msg_send![&text, setTextColor: &*color(0.129, 0.247, 0.251)];
                    let _: () = msg_send![&text, setBackgroundColor: &*color(0.851, 0.91, 0.875)];
                    let _: () = msg_send![&transcript_scroll, setDocumentView: &*text];
                    let _: () = msg_send![&content, addSubview: &*transcript_scroll];
                    button(
                        &content,
                        &self.delegate,
                        "Copy",
                        6,
                        rect(20.0, 28.0, 144.0, 36.0),
                        false,
                    );
                    button(
                        &content,
                        &self.delegate,
                        "Dismiss",
                        7,
                        rect(176.0, 28.0, 144.0, 36.0),
                        false,
                    );
                }
                Page::Settings => {
                    label(
                        &content,
                        "English model",
                        rect(20.0, 442.0, 300.0, 22.0),
                        13.0,
                    );
                    let model = popup(
                        &content,
                        &[
                            "base.en (default)".into(),
                            "tiny.en-q5_1".into(),
                            "small.en".into(),
                            "Custom profile".into(),
                        ],
                        rect(20.0, 408.0, 300.0, 30.0),
                    );
                    let selection = match self.settings.model {
                        Model::Base => 0isize,
                        Model::Tiny => 1,
                        Model::Small => 2,
                        Model::Custom => 3,
                    };
                    let _: () = msg_send![&model, selectItemAtIndex: selection];
                    self.model_picker = Some(model);
                    label(
                        &content,
                        "Custom manifest (absolute path)",
                        rect(20.0, 378.0, 300.0, 22.0),
                        13.0,
                    );
                    let field: Allocated<AnyObject> = msg_send![class!(NSTextField), alloc];
                    let field: Retained<AnyObject> =
                        msg_send![field, initWithFrame: rect(20.0, 344.0, 300.0, 28.0)];
                    let _: () = msg_send![&field, setStringValue: &*NSString::from_str(&self.settings.engine_profile_path)];
                    let _: () = msg_send![&content, addSubview: &*field];
                    self.profile_field = Some(field);
                    label(
                        &content,
                        "Registered toggle shortcut",
                        rect(20.0, 308.0, 300.0, 22.0),
                        13.0,
                    );
                    self.shortcut_names = policy::SHORTCUTS
                        .iter()
                        .map(|(name, _, _)| (*name).to_owned())
                        .collect();
                    let current =
                        policy::shortcut_name(&self.settings.shortcut).unwrap_or_default();
                    if !current.is_empty() && !self.shortcut_names.contains(&current) {
                        self.shortcut_names.push(current.clone());
                    }
                    let shortcut = popup(
                        &content,
                        &self.shortcut_names,
                        rect(20.0, 274.0, 300.0, 30.0),
                    );
                    let selected = self
                        .shortcut_names
                        .iter()
                        .position(|name| name == &current)
                        .unwrap_or(0) as isize;
                    let _: () = msg_send![&shortcut, selectItemAtIndex: selected];
                    self.shortcut_picker = Some(shortcut);
                    let insertion = button(
                        &content,
                        &self.delegate,
                        "Automatic cursor insertion",
                        0,
                        rect(20.0, 226.0, 300.0, 30.0),
                        false,
                    );
                    let _: () = msg_send![&insertion, setButtonType: 3usize];
                    let _: () = msg_send![&insertion, setState: if self.settings.automatic_insertion { 1isize } else { 0isize }];
                    self.insertion_button = Some(insertion);
                    let status = if permissions::accessibility_trusted() {
                        "Accessibility ready. Browsers still need Review / Copy."
                    } else {
                        "Insertion needs Accessibility. Browsers use Review / Copy."
                    };
                    label(&content, status, rect(20.0, 166.0, 300.0, 50.0), 12.0);
                    button(
                        &content,
                        &self.delegate,
                        "Accessibility setup…",
                        11,
                        rect(20.0, 124.0, 300.0, 32.0),
                        false,
                    );
                    button(
                        &content,
                        &self.delegate,
                        "Microphone settings…",
                        12,
                        rect(20.0, 84.0, 300.0, 32.0),
                        false,
                    );
                    button(
                        &content,
                        &self.delegate,
                        "Save settings",
                        8,
                        rect(20.0, 28.0, 300.0, 36.0),
                        false,
                    );
                }
            }
            self.content = Some(content);
        }
    }
}

fn rect(left: f64, bottom: f64, width: f64, height: f64) -> NSRect {
    NSRect::new(NSPoint::new(left, bottom), NSSize::new(width, height))
}

unsafe fn color(red: f64, green: f64, blue: f64) -> Retained<AnyObject> {
    msg_send![class!(NSColor), colorWithSRGBRed: red, green: green, blue: blue, alpha: 1.0f64]
}

unsafe fn font(size: f64) -> Retained<AnyObject> {
    msg_send![class!(NSFont), systemFontOfSize: size]
}

unsafe fn rounded(view: &AnyObject, radius: f64, color: &AnyObject) {
    let _: () = msg_send![view, setWantsLayer: Bool::YES];
    let layer: Retained<AnyObject> = msg_send![view, layer];
    let _: () = msg_send![&layer, setCornerRadius: radius];
    let _: () = msg_send![&layer, setMasksToBounds: Bool::YES];
    let cg_color: *const std::ffi::c_void = msg_send![color, CGColor];
    let _: () = msg_send![&layer, setBackgroundColor: cg_color];
}

unsafe fn label(parent: &AnyObject, title: &str, frame: NSRect, size: f64) -> Retained<AnyObject> {
    let label: Retained<AnyObject> =
        msg_send![class!(NSTextField), wrappingLabelWithString: &*NSString::from_str(title)];
    let _: () = msg_send![&label, setFrame: frame];
    let _: () = msg_send![&label, setFont: &*font(size)];
    let _: () = msg_send![&label, setTextColor: &*color(0.129, 0.247, 0.251)];
    let _: () = msg_send![&label, setSelectable: Bool::YES];
    let _: () = msg_send![parent, addSubview: &*label];
    label
}

unsafe fn button(
    parent: &AnyObject,
    delegate: &Delegate,
    title: &str,
    tag: isize,
    frame: NSRect,
    pill: bool,
) -> Retained<AnyObject> {
    let marker = MainThreadMarker::new().expect("main thread");
    let button: Retained<FirstMouseButton> =
        msg_send![FirstMouseButton::alloc(marker), initWithFrame: frame];
    let _: () = msg_send![&button, setTitle: &*NSString::from_str(title)];
    let _: () = msg_send![&button, setAccessibilityLabel: &*NSString::from_str(title)];
    let _: () = msg_send![&button, setTarget: delegate];
    let _: () = msg_send![&button, setAction: sel!(action:)];
    let _: () = msg_send![&button, setTag: tag];
    let _: () = msg_send![&button, setBezelStyle: 1usize];
    if pill {
        let _: () = msg_send![&button, setBordered: Bool::NO];
        let _: () = msg_send![&button, setContentTintColor: &*color(1.0, 0.973, 0.933)];
    }
    let _: () = msg_send![parent, addSubview: &*button];
    Retained::cast_unchecked(button)
}

unsafe fn popup(parent: &AnyObject, names: &[String], frame: NSRect) -> Retained<AnyObject> {
    let popup: Allocated<AnyObject> = msg_send![class!(NSPopUpButton), alloc];
    let popup: Retained<AnyObject> = msg_send![popup, initWithFrame: frame, pullsDown: Bool::NO];
    for title in names {
        let _: () = msg_send![&popup, addItemWithTitle: &*NSString::from_str(title)];
    }
    let _: () = msg_send![parent, addSubview: &*popup];
    popup
}

unsafe fn item(
    menu: &AnyObject,
    delegate: Option<&Delegate>,
    title: &str,
    action: objc2::runtime::Sel,
    key: &str,
    tag: isize,
) -> Retained<AnyObject> {
    let item: Allocated<AnyObject> = msg_send![class!(NSMenuItem), alloc];
    let item: Retained<AnyObject> = msg_send![item, initWithTitle: &*NSString::from_str(title), action: action, keyEquivalent: &*NSString::from_str(key)];
    if let Some(delegate) = delegate {
        let _: () = msg_send![&item, setTarget: delegate];
    }
    let _: () = msg_send![&item, setTag: tag];
    let _: () = msg_send![menu, addItem: &*item];
    item
}

unsafe fn action_menu(delegate: &Delegate) -> Retained<AnyObject> {
    let menu: Retained<AnyObject> = msg_send![class!(NSMenu), new];
    for (title, tag) in [
        ("Open Wisper Rust", 1),
        ("Review", 2),
        ("Settings…", 3),
        ("Record / Stop", 4),
        ("Cancel", 5),
        ("Quit Open Wisper Rust", 9),
    ] {
        item(
            &menu,
            Some(delegate),
            title,
            sel!(action:),
            if tag == 9 { "q" } else { "" },
            tag,
        );
    }
    menu
}

unsafe fn make_menu(delegate: &Delegate) -> Retained<AnyObject> {
    let menu: Retained<AnyObject> = msg_send![class!(NSMenu), new];
    let application_item = item(&menu, None, "Open Wisper Rust", sel!(action:), "", 0);
    let submenu = action_menu(delegate);
    let _: () = msg_send![&application_item, setSubmenu: &*submenu];
    let edit_item = item(&menu, None, "Edit", sel!(action:), "", 0);
    let edit_menu: Retained<AnyObject> = msg_send![class!(NSMenu), new];
    for (title, selector, key) in [
        ("Undo", sel!(undo:), "z"),
        ("Cut", sel!(cut:), "x"),
        ("Copy", sel!(copy:), "c"),
        ("Paste", sel!(paste:), "v"),
        ("Select All", sel!(selectAll:), "a"),
    ] {
        item(&edit_menu, None, title, selector, key, 0);
    }
    let _: () = msg_send![&edit_item, setSubmenu: &*edit_menu];
    menu
}
