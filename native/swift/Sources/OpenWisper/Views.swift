import AppKit
import SwiftUI
import WisperCore

private struct PebblePalette {
    let dark: Bool
    var surface: Color { dark ? Color(red: 0.08, green: 0.15, blue: 0.15) : Color(red: 1, green: 0.973, blue: 0.933) }
    var ink: Color { dark ? Color(red: 0.91, green: 0.95, blue: 0.91) : Color(red: 0.129, green: 0.247, blue: 0.251) }
    var secondary: Color { dark ? Color(red: 0.69, green: 0.79, blue: 0.74) : Color(red: 0.349, green: 0.420, blue: 0.396) }
    var seaGlass: Color { dark ? Color(red: 0.15, green: 0.27, blue: 0.25) : Color(red: 0.851, green: 0.910, blue: 0.875) }
    var teal: Color { dark ? Color(red: 0.43, green: 0.76, blue: 0.69) : Color(red: 0.157, green: 0.357, blue: 0.349) }
    var copper: Color { dark ? Color(red: 1, green: 0.69, blue: 0.52) : Color(red: 0.608, green: 0.290, blue: 0.188) }
    var copperSurface: Color { dark ? Color(red: 0.28, green: 0.19, blue: 0.16) : Color(red: 0.965, green: 0.890, blue: 0.827) }
    var navigation: Color { dark ? seaGlass : Color(red: 0.910, green: 0.925, blue: 0.886) }
}

@MainActor final class WindowNavigation: ObservableObject {
    @Published var reviewSelected = false
}

@MainActor struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: SessionCoordinator
    var previewMemory: TranscriptionMemory? = nil
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var navigationState = WindowNavigation()
    private var reviewSelected: Bool { navigationState.reviewSelected }
    private var palette: PebblePalette { PebblePalette(dark: colorScheme == .dark) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "mic").font(.system(size: 18, weight: .medium))
                    .foregroundStyle(palette.teal).accessibilityHidden(true)
                Text("Open Wisper").font(.system(size: 17, weight: .semibold))
            }
            .padding(.top, 12).padding(.bottom, 18)
            HStack(spacing: 3) {
                navigation("Ready", selected: !model.settingsOpen && !reviewSelected) {
                    model.settingsOpen = false; navigationState.reviewSelected = false
                }
                .keyboardShortcut("1", modifiers: [.command])
                navigation("Review", selected: !model.settingsOpen && reviewSelected) {
                    model.settingsOpen = false; navigationState.reviewSelected = true
                }
                .disabled(session.phase.isActive)
                .keyboardShortcut("2", modifiers: [.command])
                navigation("Settings", selected: model.settingsOpen) {
                    model.settingsOpen = true; model.refreshPermissions()
                }
                .keyboardShortcut("3", modifiers: [.command])
            }
            .padding(3).background(palette.navigation, in: Capsule()).padding(.horizontal, 22)
            if model.settingsOpen {
                SettingsView(model: model)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 0) {
                            if reviewSelected && !session.phase.isActive { review } else { ready }
                            recovery
                        }
                        .padding(.horizontal, 26).padding(.top, 26).padding(.bottom, 24)
                        .frame(maxWidth: .infinity)
                    }
                    if reviewSelected && !session.phase.isActive && !session.transcript.isEmpty {
                        reviewActions.padding(.horizontal, 26).padding(.bottom, 16)
                    }
                    TranscriptionMemoryView(memory: previewMemory ?? session.lastTranscriptionMemory, metrics: session.metrics, secondary: palette.secondary)
                        .padding(.horizontal, 26).padding(.bottom, 18)
                }
            }
        }
        .foregroundStyle(palette.ink).tint(palette.teal)
        .frame(minWidth: 340, idealWidth: 360, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity, alignment: .top)
        .background(palette.surface)
        .onChange(of: session.transcript) { _, transcript in navigationState.reviewSelected = !transcript.isEmpty }
        .onChange(of: session.failure) { _, failure in if failure != nil { navigationState.reviewSelected = true } }
        .onAppear {
            navigationState.reviewSelected = !session.transcript.isEmpty || session.failure != nil
        }
    }

    private func navigation(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12, weight: selected ? .semibold : .regular))
                .frame(maxWidth: .infinity).padding(.vertical, 8)
                .background(selected ? palette.surface : Color.clear, in: Capsule())
        }
        .buttonStyle(PebbleNavigationStyle()).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel("\(title) tab")
    }

    private var ready: some View {
        VStack(spacing: 0) {
            Text(session.phase == .recording ? "Recording" : session.phase.isActive ? session.phase.title : model.engineReady ? "Ready to\ndictate." : model.checkingEngine ? "Checking engine" : "Set up dictation")
                .font(.system(size: 27, weight: .medium)).tracking(-0.6)
                .frame(maxWidth: 250).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(session.phase.isActive ? activeDescription : model.engineReady ? "Place your cursor, then use the shortcut." : "Choose a local model in Settings.")
                .font(.system(size: 13)).lineSpacing(5).foregroundStyle(palette.secondary)
                .frame(maxWidth: 270).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            Button {
                if !session.phase.isActive && !model.engineReady { model.settingsOpen = true }
                else { model.toggle() }
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: session.phase == .recording ? "stop.fill" : session.phase.isActive ? "ellipsis" : "mic")
                        .font(.system(size: 22, weight: .medium)).accessibilityHidden(true)
                    Text(session.phase == .recording ? "Stop" : session.phase.isActive ? "Working" : model.checkingEngine ? "Verifying" : model.engineReady ? "Start" : "Set up")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(width: 76, height: 76)
                .foregroundStyle(session.phase == .recording ? palette.copper : colorScheme == .dark ? palette.surface : .white)
                .background(session.phase == .recording ? palette.copperSurface : palette.teal, in: Circle())
                .contentShape(Circle())
            }
            .buttonStyle(PebbleNavigationStyle()).padding(.top, 22)
            .accessibilityLabel(session.phase == .recording ? "Stop recording" : session.phase.isActive ? session.phase.title : model.checkingEngine ? "Verifying engine" : model.engineReady ? "Start dictation" : "Set up local transcription")
            .accessibilityHint(!model.engineReady && !session.phase.isActive ? "Opens Settings" : "")
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled((session.phase.isActive && session.phase != .recording) || (!session.phase.isActive && model.checkingEngine))
            if session.phase == .recording, let started = session.recordingStartedAt {
                Text(started, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(palette.secondary).padding(.top, 10)
            } else if !session.phase.isActive {
                Text(model.shortcutLabel).font(.caption.weight(.medium)).foregroundStyle(palette.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(palette.navigation, in: Capsule()).padding(.top, 12)
                    .accessibilityLabel("Dictation shortcut: \(model.shortcutLabel)")
            }
            if session.phase.isActive {
                Button("Cancel dictation") { model.cancel() }
                    .font(.caption).padding(.top, 12)
                    .keyboardShortcut(.escape, modifiers: []).disabled(session.phase == .cancelling)
            } else if !model.settings.automaticInsertion {
                Text("Automatic insertion is off. Review and copy after dictating.")
                    .font(.caption).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 12)
            }
        }
    }

    private var review: some View {
        VStack(spacing: 14) {
            Text(session.failure != nil ? "Dictation interrupted" : session.transcript.isEmpty ? "No transcript yet" : "Review transcript")
                .font(.system(size: 24, weight: .medium)).tracking(-0.5).multilineTextAlignment(.center)
            if !session.transcript.isEmpty {
                Text(session.transcript).textSelection(.enabled).font(.system(size: 15)).lineSpacing(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(session.deliveryResult?.message ?? "Transcript ready to copy.")
                    .font(.caption).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Closing this window or starting a new recording clears this text.")
                    .font(.caption).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                if session.failure == nil {
                    Text("Use your shortcut to start dictating.")
                        .font(.callout).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
                }
                Button("Go to Ready") { navigationState.reviewSelected = false }
            }
        }
    }

    private var reviewActions: some View {
        HStack(spacing: 8) {
            Button("Clear") { session.dismissResult(); navigationState.reviewSelected = false }
                .buttonStyle(PebbleActionStyle(background: palette.navigation, foreground: palette.ink))
                .accessibilityLabel("Clear transcript")
            Button(session.deliveryResult?.outcome == .copied ? "Copied" : copyFailed(session) ? "Try Copy again" : "Copy") { session.copyResult() }
                .buttonStyle(PebbleActionStyle(background: palette.teal, foreground: colorScheme == .dark ? palette.surface : .white))
                .keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }

    @ViewBuilder private var recovery: some View {
        if let message = session.failure ?? model.notice {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(palette.copper).fixedSize(horizontal: false, vertical: true)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(palette.copperSurface, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Attention: \(message)").padding(.top, 18)
        }
        if model.settings.automaticInsertion && !model.permissions.accessibilityGranted && !session.phase.isActive {
            VStack(spacing: 6) {
                Text("Allow Accessibility once so dictation can appear at your cursor.").fixedSize(horizontal: false, vertical: true)
                Button("Enable cursor insertion…") { model.permissions.openAccessibilitySettings() }
            }
            .font(.caption).foregroundStyle(palette.secondary).multilineTextAlignment(.center).padding(.top, 18)
        }
    }

    private var activeDescription: String {
        if session.phase == .cancelling { return "Cleaning up this dictation." }
        if session.automaticallyStopped { return "The recording limit was reached. Finishing your transcript." }
        if session.phase == .recording {
            return model.settings.automaticInsertion
                ? "Stop here to review or copy your transcript. Use \(model.shortcutLabel) in your editor to insert at the cursor."
                : "Stop to review or copy your transcript."
        }
        return "You can cancel dictation at any time."
    }
}

@MainActor private func copyFailed(_ session: SessionCoordinator) -> Bool {
    session.deliveryResult?.outcome == .copyFailed
}

private struct PebbleNavigationStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

private struct PebbleActionStyle: ButtonStyle {
    let background: Color
    let foreground: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity).padding(.vertical, 11)
            .foregroundStyle(foreground).background(background, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

private struct TranscriptionMemoryView: View {
    let memory: TranscriptionMemory?
    let metrics: SessionMetrics?
    let secondary: Color
    @State private var showsExplanation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().padding(.bottom, 6)
            HStack(alignment: .firstTextBaseline) {
                Label("Transcription peak", systemImage: "memorychip")
                    .font(.callout.weight(.medium))
                Button { showsExplanation.toggle() } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.plain).foregroundStyle(secondary)
                .accessibilityLabel("About peak memory")
                .accessibilityHint("Shows memory and session timing details")
                .popover(isPresented: $showsExplanation) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Maximum resident memory used by the transcription engine during its last completed run, reported by macOS when the worker exits. Includes the model and engine working memory. Excludes the app and system services. This is RSS, not Activity Monitor’s physical footprint. Kept until the next engine result or until you quit; nothing is saved to disk.")
                        if let metrics {
                            Text(String(format: "%.1f s audio · %.1f s transcription", metrics.audioDuration, metrics.inferenceDuration))
                                .monospacedDigit()
                        }
                    }.font(.callout).padding(18).frame(width: 320)
                }
                Spacer(minLength: 8)
                Text(memory?.formattedPeak ?? "—")
                    .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var advanced = false
    @State private var engineDetails = false
    private var palette: PebblePalette { PebblePalette(dark: colorScheme == .dark) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("Transcription engine") {
                    Picker("Offline Whisper model", selection: Binding(
                        get: { model.settings.whisperModel ?? .base }, set: { model.chooseModel($0) }
                    )) {
                        Text("Tiny English (fastest)").tag(WhisperModel.tiny)
                        Text("Base English (default)").tag(WhisperModel.base)
                        Text("Small English").tag(WhisperModel.small)
                        Text("Custom profile…").tag(WhisperModel.custom)
                    }
                    .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Offline Whisper model")
                    Text(model.checkingEngine ? "Verifying engine and model…" : model.engineReady ? "Engine ready" : "Engine unavailable. Open details to set up.")
                        .font(.caption).foregroundStyle(model.engineReady || model.checkingEngine ? palette.secondary : palette.copper)
                        .fixedSize(horizontal: false, vertical: true)
                    DisclosureGroup("Engine details", isExpanded: $engineDetails) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.engineDescription).foregroundStyle(model.engineReady ? palette.secondary : palette.copper)
                                .fixedSize(horizontal: false, vertical: true)
                            if !model.settings.engineProfilePath.isEmpty {
                                Text(model.settings.engineProfilePath).font(.caption).foregroundStyle(palette.secondary)
                                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                            }
                            HStack {
                                Button("Choose profile…") { model.chooseProfile() }
                                Button("Verify") { model.verifyEngine() }
                                    .disabled(model.settings.engineProfilePath.isEmpty || model.checkingEngine)
                                if model.checkingEngine { ProgressView().controlSize(.small) }
                            }
                            .controlSize(.small)
                        }
                        .padding(.top, 8)
                    }
                    .font(.caption)
                }
                Divider().overlay(palette.navigation)
                section("Activation shortcut") {
                    Picker("Key", selection: settingsBinding(\.hotkey.keyCode)) {
                        ForEach(HotkeyCombination.supportedKeys, id: \.code) { key in Text(key.name).tag(key.code) }
                    }
                    .pickerStyle(.menu)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 10) {
                        modifier("Command", .command)
                        modifier("Shift", .shift)
                        modifier("Option", .option)
                        modifier("Control", .control)
                    }
                    Text("\(model.shortcutLabel) · press once to start, again to stop")
                        .font(.caption).foregroundStyle(palette.secondary)
                }
                Divider().overlay(palette.navigation)
                section("Text delivery") {
                    Toggle("Insert at cursor when dictation stops", isOn: settingsBinding(\.automaticInsertion))
                        .toggleStyle(.checkbox)
                    Text("Accessibility: \(model.permissions.accessibilityGranted ? "Allowed" : "Needed for cursor insertion")")
                        .font(.caption).foregroundStyle(palette.secondary)
                    Text("Paste temporarily uses the clipboard and restores it only if nothing else was copied. If insertion fails, use Review or Copy.")
                        .font(.caption).foregroundStyle(palette.secondary).fixedSize(horizontal: false, vertical: true)
                    if model.settings.automaticInsertion && !model.permissions.accessibilityGranted {
                        Button("Enable cursor insertion…") { model.permissions.openAccessibilitySettings() }
                    }
                }
                Divider().overlay(palette.navigation)
                section("Permissions") {
                    Text("Microphone: \(model.permissions.microphoneStatus)")
                    HStack {
                        Button("Microphone settings…") { model.permissions.openMicrophoneSettings() }
                        Button("Refresh") { model.refreshPermissions() }
                    }
                    .controlSize(.small)
                }
                DisclosureGroup("Recording limits", isExpanded: $advanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Automatic stop", selection: settingsBinding(\.maximumDuration)) {
                            Text("1 minute").tag(60.0)
                            Text("3 minutes").tag(180.0)
                            Text("5 minutes").tag(300.0)
                        }
                        Picker("Transcription timeout", selection: settingsBinding(\.workerTimeout)) {
                            Text("1 minute").tag(60.0)
                            Text("2 minutes").tag(120.0)
                            Text("5 minutes").tag(300.0)
                        }
                        Button("Reveal settings file") { model.revealSettings() }
                    }
                    .padding(.top, 8)
                }
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(palette.copper)
                }
            }
            .font(.system(size: 12)).padding(26).frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.coordinator.phase.isActive)
        }
        .onAppear { engineDetails = !model.engineReady }
        .onChange(of: model.engineReady) { _, ready in if !ready && !model.checkingEngine { engineDetails = true } }
        .onChange(of: model.checkingEngine) { _, checking in if !checking && !model.engineReady { engineDetails = true } }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsBinding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in
            var proposed = model.settings
            proposed[keyPath: keyPath] = value
            model.save(proposed)
        })
    }

    private func modifier(_ name: String, _ modifier: HotkeyModifiers) -> some View {
        Toggle(name, isOn: Binding(get: { model.settings.hotkey.modifiers.contains(modifier) }, set: { enabled in
            var proposed = model.settings
            if enabled { proposed.hotkey.modifiers.insert(modifier) }
            else { proposed.hotkey.modifiers.remove(modifier) }
            model.save(proposed)
        })).toggleStyle(.checkbox).font(.caption)
    }
}

@MainActor struct RecordingIndicatorView: View {
    @ObservedObject var session: SessionCoordinator
    let layout: IndicatorLayout
    let feedback: IndicatorFeedback
    let setupRequired: Bool
    let stop: () -> Void
    let cancel: () -> Void
    let review: () -> Void
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Button(action: review) {
                    HStack(spacing: 7) {
                        Image(systemName: session.phase == .recording ? "mic" : feedback == .copied || feedback == .inserted ? "checkmark" : session.needsReview ? "text.alignleft" : "waveform")
                            .font(.system(size: 14)).foregroundStyle(Color(red: 0.71, green: 0.85, blue: 0.80))
                            .accessibilityHidden(true)
                        Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                        if session.phase == .recording, let date = session.recordingStartedAt {
                            Text(date, style: .timer).font(.system(size: 11).monospacedDigit())
                                .frame(width: 38, alignment: .trailing)
                                .foregroundStyle(Color(red: 0.77, green: 0.86, blue: 0.82))
                                .accessibilityLabel("Recording duration")
                        }
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium))
                            .accessibilityHidden(true)
                    }
                    .frame(maxWidth: .infinity, minHeight: 32).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help(session.failure ?? session.deliveryResult?.message ??
                    (setupRequired ? "Open Settings to set up the local engine" : "Open Open Wisper"))
                .accessibilityLabel("\(title). Open Open Wisper window")
                if session.phase == .recording {
                    Button(action: stop) {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                            .frame(width: 28, height: 26)
                            .foregroundStyle(Color(red: 0.608, green: 0.290, blue: 0.188))
                            .background(Color(red: 0.965, green: 0.890, blue: 0.827), in: Capsule())
                    }
                    .buttonStyle(.plain).accessibilityLabel("Stop recording").help("Stop recording")
                }
                if !session.phase.isActive && session.needsReview && !session.transcript.isEmpty && feedback != .copied {
                    Button(copyFailed(session) ? "Retry" : "Copy", action: copy).font(.system(size: 11, weight: .medium))
                        .buttonStyle(.plain).padding(.horizontal, 7).frame(height: 26)
                        .background(.white.opacity(0.12), in: Capsule())
                        .accessibilityLabel(copyFailed(session) ? "Retry Copy" : "Copy")
                        .accessibilityHint("Copies the transcript to the clipboard")
                }
                Button(action: session.phase.isActive ? cancel : dismiss) {
                    Image(systemName: "xmark").font(.system(size: 11)).frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(session.phase.isActive ? "Cancel dictation" : "Dismiss")
                .accessibilityLabel(session.phase.isActive ? "Cancel dictation" : "Dismiss")
                .disabled(session.phase == .cancelling)
            }
            .padding(.horizontal, 12).frame(height: 44)
        }
        .foregroundStyle(Color(red: 1, green: 0.973, blue: 0.933))
        .frame(width: layout.frame.width, height: layout.frame.height)
        .background(Color(red: 0.129, green: 0.247, blue: 0.251), in: Capsule())
    }
    private var title: String {
        if session.phase == .recording { return "Listening" }
        if session.phase == .preparing { return "Preparing" }
        if session.phase == .cancelling { return "Cancelling" }
        if session.phase == .transcribing { return "Transcribing" }
        if session.phase == .finalizing { return "Finishing" }
        if session.phase == .transforming { return "Preparing text" }
        if session.phase == .deliveryPending { return "Checking cursor" }
        if session.phase.isActive { return "Processing" }
        if feedback == .copied { return "Copied" }
        if session.needsReview { return copyFailed(session) ? "Copy failed" : session.failure != nil ? "Interrupted" : "Review" }
        if setupRequired { return "Set up engine" }
        switch feedback {
        case .inserted: return "Inserted"
        case .insertionRequested: return "Insertion requested"
        case .cancelled: return "Cancelled"
        default: return "Ready"
        }
    }
}
