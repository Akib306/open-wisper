import AppKit
import SwiftUI
import WisperCore

@MainActor final class NonactivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
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
    private var indicator: NonactivatingPanel?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var shuttingDown = false
    private var shutdownComplete = false

    init(profileURL: URL?) {
        model = AppModel(profileURL: profileURL)
        super.init()
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
        model.onPhase = { [weak self] phase in self?.phaseChanged(phase) }
        model.onNeedsWindow = { [weak self] in self?.showWindow() }
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
        showWindow()
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 590),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Open Wisper Swift"
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: MainView(model: model, session: model.coordinator))
            window.contentMinSize = NSSize(width: 460, height: 540)
            window.setFrameAutosaveName("OpenWisperReview")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.refreshPermissions()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing review discards in-memory text, while active capture continues.
        model.coordinator.dismissResult()
    }

    private func phaseChanged(_ phase: SessionPhase) {
        toggleItem?.title = phase == .recording ? "Stop recording" : "Start dictation"
        toggleItem?.isEnabled = !phase.isActive || phase == .recording
        cancelItem?.isHidden = !phase.isActive
        cancelItem?.isEnabled = phase != .cancelling
        statusItem?.button?.image = NSImage(systemSymbolName: phase == .recording ? "mic.fill" : "waveform",
                                           accessibilityDescription: phase.title)
        statusItem?.button?.toolTip = "Open Wisper Swift — \(phase.title)"
        if phase.isActive || model.coordinator.needsReview {
            showIndicator()
        } else {
            indicator?.orderOut(nil)
        }
        // Completion and failure must never take focus from the destination.
        // Review is opened only by an explicit menu/panel action.
    }

    private func showIndicator() {
        if indicator == nil {
            let panel = NonactivatingPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 64),
                                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.contentView = NSHostingView(rootView: RecordingIndicatorView(session: model.coordinator,
                stop: { [weak model] in model?.coordinator.stop() }, cancel: { [weak model] in model?.cancel() },
                review: { [weak self] in
                    self?.indicator?.orderOut(nil)
                    self?.model.settingsOpen = false
                    self?.showWindow()
                }, copy: { [weak self] in
                    self?.model.coordinator.copyResult()
                    self?.indicator?.orderOut(nil)
                }, dismiss: { [weak self] in
                    self?.model.coordinator.dismissResult()
                    self?.indicator?.orderOut(nil)
                }))
            indicator = panel
        }
        if indicator?.isVisible != true {
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
            if let frame = screen?.visibleFrame {
                indicator?.setFrameOrigin(NSPoint(x: frame.midX - 170, y: frame.minY + 28))
            }
            indicator?.orderFrontRegardless()
        }
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
