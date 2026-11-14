import AppKit
import Combine
import SwiftUI
import WisperCore

@MainActor final class NonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

@MainActor final class IndicatorHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let reopenNotification = Notification.Name("dev.akib.openwisper.swift.reopen")
    let model: AppModel
    private var reopenObserver: NSObjectProtocol?
    private var readinessObserver: NSObjectProtocol?
    private var statusItem: NSStatusItem?
    private var toggleItem: NSMenuItem?
    private var cancelItem: NSMenuItem?
    private var window: NSWindow?
    private let navigationState = WindowNavigation()
    private var indicator: NonactivatingPanel?
    private var indicatorDismissal: Task<Void, Never>?
    private var displayObserver: NSObjectProtocol?
    private(set) var indicatorFeedback: IndicatorFeedback = .hidden
    private var resultObservation: AnyCancellable?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var shuttingDown = false
    private var shutdownComplete = false

    convenience init(profileURL: URL?) {
        self.init(model: AppModel(profileURL: profileURL))
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        model.onPhase = { [weak self] phase in self?.phaseChanged(phase) }
        // Copy and Dismiss change the result without changing session phase.
        // Reconcile after @Published has committed the result, including actions
        // performed in the separate review window.
        resultObservation = model.coordinator.$deliveryResult.dropFirst().sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.shuttingDown else { return }
                self.phaseChanged(self.model.coordinator.phase)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMenu()
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: Self.reopenNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.model.coordinator.phase.isActive { self.showIndicator() }
                    else { self.showWindow() }
                }
            }
        readinessObserver = DistributedNotificationCenter.default().addObserver(forName: DeliveryDiagnostics.request,
            object: nil, queue: .main) { [weak self] note in
                guard let id = note.object as? String, UUID(uuidString: id) != nil else { return }
                Task { @MainActor in
                    guard let self else { return }
                    let report = DeliveryDiagnostics.report(automaticInsertion: self.model.settings.automaticInsertion,
                        source: "running Swift app")
                    guard let data = try? JSONEncoder().encode(report) else { return }
                    DistributedNotificationCenter.default().postNotificationName(DeliveryDiagnostics.response,
                        object: id, userInfo: ["report": String(decoding: data, as: UTF8.self)], deliverImmediately: true)
                }
            }
        model.onNeedsSetup = { [weak self] in
            guard let self else { return }
            self.indicatorDismissal?.cancel()
            self.indicatorDismissal = nil
            self.indicatorFeedback = .review
            self.showIndicator()
        }
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, let id = self.model.coordinator.activeSessionID else { return }
                self.model.coordinator.captureFailed(sessionID: id, message: "Dictation stopped because this Mac is going to sleep. Start a new recording after waking.")
            }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.model.refreshPermissions()
                self?.model.coordinator.prepareDeliveryForFrontmostApp()
            }
        })
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.indicator?.isVisible == true else { return }
                    self.showIndicator()
                }
            }
        if model.coordinator.phase != .idle { phaseChanged(model.coordinator.phase) }
    }

    private func installMenu() {
        let mainMenu = NSMenu()
        let appMenu = NSMenu()
        let application = NSMenuItem()
        application.submenu = appMenu
        mainMenu.addItem(application)
        let settingsCommand = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsCommand.target = self
        appMenu.addItem(settingsCommand)
        appMenu.addItem(.separator())
        let quitCommand = NSMenuItem(title: "Quit Open Wisper Swift", action: #selector(quit), keyEquivalent: "q")
        quitCommand.target = self
        appMenu.addItem(quitCommand)
        let edit = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.submenu = editMenu
        mainMenu.addItem(edit)
        NSApp.mainMenu = mainMenu

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Open Wisper Swift")
        item.button?.toolTip = "Open Wisper Swift — local dictation"
        let menu = NSMenu()
        let toggle = NSMenuItem(title: "Start dictation", action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        toggleItem = toggle
        menu.addItem(toggle)
        let cancel = NSMenuItem(title: "Cancel dictation", action: #selector(cancelRecording), keyEquivalent: "")
        cancel.target = self
        cancel.isHidden = true
        cancelItem = cancel
        menu.addItem(cancel)
        menu.addItem(.separator())
        let review = NSMenuItem(title: "Open Wisper Swift…", action: #selector(showWindow), keyEquivalent: "")
        review.target = self
        menu.addItem(review)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Open Wisper Swift", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.autoenablesItems = false
        item.menu = menu
    }

    @objc private func toggleRecording() {
        model.toggle()
    }
    @objc private func cancelRecording() { model.cancel() }
    @objc private func showSettings() { model.settingsOpen = true; showWindow() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc func showWindow() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 480),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Open Wisper Swift"
            window.titlebarAppearsTransparent = true
            window.backgroundColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.08, green: 0.15, blue: 0.15, alpha: 1)
                    : NSColor(srgbRed: 1, green: 0.973, blue: 0.933, alpha: 1)
            }
            window.contentView = NSHostingView(rootView: MainView(model: model, session: model.coordinator, navigationState: navigationState))
            window.contentMinSize = NSSize(width: 340, height: 420)
            window.setFrameAutosaveName("OpenWisperPebbleCompact")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.refreshPermissions()
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing review discards in-memory text; active capture continues.
        model.coordinator.dismissResult()
        navigationState.reviewSelected = false
    }

    private func phaseChanged(_ phase: SessionPhase) {
        toggleItem?.title = phase == .recording ? "Stop recording" : "Start dictation"
        toggleItem?.isEnabled = !phase.isActive || phase == .recording
        cancelItem?.isHidden = !phase.isActive
        cancelItem?.isEnabled = phase != .cancelling
        statusItem?.button?.image = NSImage(systemSymbolName: phase == .recording ? "mic.fill" : "waveform",
                                           accessibilityDescription: phase.title)
        statusItem?.button?.toolTip = "Open Wisper Swift — \(phase.title)"
        let feedback = IndicatorFeedback(phase: phase, needsReview: model.coordinator.needsReview,
            outcome: model.coordinator.deliveryResult?.outcome)
        if feedback == indicatorFeedback && indicatorDismissal != nil { return }
        indicatorDismissal?.cancel()
        indicatorDismissal = nil
        indicatorFeedback = feedback
        if feedback != .hidden {
            showIndicator()
            if feedback == .inserted || feedback == .insertionRequested || feedback == .cancelled {
                indicatorDismissal = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(1.8)) }
                    catch { return }
                    guard let self, self.indicatorFeedback == feedback,
                          !self.model.coordinator.phase.isActive else { return }
                    self.indicator?.orderOut(nil)
                    self.indicatorDismissal = nil
                    self.indicatorFeedback = .hidden
                }
            }
        } else {
            indicator?.orderOut(nil)
        }
        // Completion and failure must never take focus from the destination.
        // Review is opened only by an explicit menu/panel action.
    }

    private func showIndicator() {
        let screen = indicator?.isVisible == true ? indicator?.screen :
            NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen = screen ?? NSScreen.main else { return }
        let layout = IndicatorLayout(screen: screen.frame, visibleFrame: screen.visibleFrame,
            phase: model.coordinator.phase, feedback: indicatorFeedback)
        if indicator == nil {
            let panel = NonactivatingPanel(contentRect: layout.frame,
                                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.title = "Open Wisper · Dictation"
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.animationBehavior = .none
            indicator = panel
        }
        indicator?.setFrame(layout.frame, display: true)
        indicator?.contentView = IndicatorHostingView(rootView: RecordingIndicatorView(session: model.coordinator,
                layout: layout, feedback: indicatorFeedback, setupRequired: !model.engineReady,
                stop: { [weak model] in model?.coordinator.stop() }, cancel: { [weak model] in model?.cancel() },
                review: { [weak self] in
                    guard let self else { return }
                    self.model.settingsOpen = !self.model.engineReady && !self.model.coordinator.needsReview
                    self.navigationState.reviewSelected = self.model.coordinator.needsReview
                    self.showWindow()
                }, copy: { [weak self] in
                    self?.model.coordinator.copyResult()
                }, dismiss: { [weak self] in
                    guard let self else { return }
                    self.model.coordinator.dismissResult()
                    self.navigationState.reviewSelected = false
                    self.indicatorDismissal?.cancel()
                    self.indicatorDismissal = nil
                    self.indicatorFeedback = .hidden
                    self.indicator?.orderOut(nil)
                }))
        indicator?.orderFrontRegardless()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if model.coordinator.phase.isActive { showIndicator() }
        else { showWindow() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shutdownComplete { return .terminateNow }
        if shuttingDown { return .terminateLater }
        shuttingDown = true
        Task { @MainActor in
            await model.shutdown()
            indicator?.orderOut(nil)
            indicatorDismissal?.cancel()
            if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
            for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            workspaceObservers.removeAll()
            if let reopenObserver { DistributedNotificationCenter.default().removeObserver(reopenObserver) }
            reopenObserver = nil
            if let readinessObserver { DistributedNotificationCenter.default().removeObserver(readinessObserver) }
            readinessObserver = nil
            shutdownComplete = true
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
