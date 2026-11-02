import AppKit
import SwiftUI
import WisperCore

@MainActor struct MainView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: SessionCoordinator
    var previewMemory: TranscriptionMemory? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .modifier(UtilityGlass())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open Wisper Swift").font(.title3.weight(.semibold))
                    Text("Local dictation").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.settingsOpen.toggle()
                    model.refreshPermissions()
                } label: {
                    Image(systemName: model.settingsOpen ? "xmark" : "gearshape")
                }
                .modifier(UtilityButtonStyle())
                .controlSize(.large)
                .help(model.settingsOpen ? "Back to dictation" : "Settings")
                .accessibilityLabel(model.settingsOpen ? "Back to dictation" : "Settings")
            }
            .padding(22)
            if model.settingsOpen {
                SettingsView(model: model)
            } else {
                dictation
            }
        }
        .frame(minWidth: 440, idealWidth: 500, maxWidth: .infinity, minHeight: 540, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dictation: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Image(systemName: session.phase == .recording ? "mic.fill" : "waveform")
                        .foregroundStyle(session.phase == .recording ? Color.red : Color.accentColor)
                        .accessibilityHidden(true)
                    Text(session.phase.isActive ? session.phase.title : session.transcript.isEmpty ? "Ready when you are" : "Your transcript")
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                    Spacer()
                    if session.phase == .recording, let started = session.recordingStartedAt {
                        Text(started, style: .timer).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Text(session.phase.isActive ? activeDescription : "Press \(model.shortcutLabel) from any app to start and stop.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            if let message = session.failure ?? model.notice {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.primary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Attention: \(message)")
            }

            if model.settings.automaticInsertion && !model.permissions.accessibilityGranted && !session.phase.isActive {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Allow Accessibility once so dictation can appear at your cursor.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    Button("Enable cursor insertion…") { model.permissions.openAccessibilitySettings() }
                }
            }

            if !session.transcript.isEmpty {
                ScrollView {
                    Text(session.transcript).font(.body).lineSpacing(5)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(14)
                }
                .frame(maxWidth: .infinity, minHeight: 125, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color(nsColor: .separatorColor)))
                .accessibilityLabel("Transcript")
                if let result = session.deliveryResult {
                    Text(result.message).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Dismiss") { session.dismissResult() }
                        .keyboardShortcut(.escape, modifiers: [])
                    Spacer()
                    Button { session.copyResult() } label: {
                        Label(session.deliveryResult?.outcome == .copied ? "Copied" : "Copy transcript", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                if let metrics = session.metrics {
                    Text(String(format: "%.1f s audio · %.1f s transcription", metrics.audioDuration, metrics.inferenceDuration))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Divider()
            } else {
                Spacer(minLength: 8)
                VStack(alignment: .leading, spacing: 10) {
                    Image(systemName: "text.cursor")
                        .font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
                        .padding(.bottom, 4).accessibilityHidden(true)
                    Text("Your voice, right where you need it.")
                        .font(.title3.weight(.medium))
                    Text(model.settings.automaticInsertion
                         ? "Place your cursor in a text field, dictate, then stop. Your words go there without opening this window."
                         : "Automatic insertion is off. Your transcript stays available here and in the menu-bar indicator.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !model.engineReady && !session.phase.isActive {
                        Button(model.checkingEngine ? "Verifying local engine…" : "Set up local transcription") { model.settingsOpen = true }
                            .disabled(model.checkingEngine)
                    }
                }
                .padding(.vertical, 12)
                Spacer(minLength: 8)
            }

            TranscriptionMemoryView(memory: previewMemory ?? session.lastTranscriptionMemory)

            HStack(spacing: 12) {
                Button { model.toggle() } label: {
                    Label(session.phase == .recording ? "Stop recording" : "Start dictation",
                          systemImage: session.phase == .recording ? "stop.fill" : "mic.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 3)
                }
                .modifier(UtilityButtonStyle(prominent: true))
                .tint(session.phase == .recording ? .red : .accentColor)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled((session.phase.isActive && session.phase != .recording) || (!model.engineReady && session.phase != .recording))
                if session.phase.isActive {
                    Button("Cancel") { model.cancel() }
                        .keyboardShortcut(.escape, modifiers: [])
                        .disabled(session.phase == .cancelling)
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "internaldrive").accessibilityHidden(true)
                Text("Processed on this Mac. No transcript history.")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22)
    }

    private var activeDescription: String {
        if session.automaticallyStopped { return "The recording limit was reached. Finishing your transcript." }
        if session.phase == .recording { return "Press \(model.shortcutLabel) again when you’re finished." }
        return "You can cancel at any time."
    }
}

private struct UtilityGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        } else {
            content.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        }
    }
}

private struct UtilityButtonStyle: ViewModifier {
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            if prominent { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if prominent { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

private struct TranscriptionMemoryView: View {
    let memory: TranscriptionMemory?
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
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("About peak memory")
                .popover(isPresented: $showsExplanation) {
                    Text("Maximum resident memory used by the transcription engine during its last completed run, reported by macOS when the worker exits. Includes the model and engine working memory. Excludes the app and system services. This is RSS, not Activity Monitor’s physical footprint. Kept until the next engine result or until you quit; nothing is saved to disk.")
                        .font(.callout).padding(18).frame(width: 320)
                }
                Spacer(minLength: 8)
                Text(memory?.formattedPeak ?? "—")
                    .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                    .textSelection(.enabled)
            }
            Text(memory == nil ? "Appears after your first transcription." : "Last engine run · Peak resident memory")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var advanced = false

    var body: some View {
        Form {
            Section("Transcription engine") {
                Text(model.engineDescription).font(.callout).foregroundStyle(model.engineReady ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.settings.engineProfilePath.isEmpty {
                    Text(model.settings.engineProfilePath).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                }
                HStack {
                    Button("Choose profile…") { model.chooseProfile() }
                    Button("Verify") { model.verifyEngine() }
                        .disabled(model.settings.engineProfilePath.isEmpty || model.checkingEngine)
                    if model.checkingEngine { ProgressView().controlSize(.small) }
                }
                Text("Use the profile created by the engine setup command in the Swift README. Setup is done once; dictation works offline.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Keyboard shortcut") {
                Picker("Key", selection: settingsBinding(\.hotkey.keyCode)) {
                    ForEach(HotkeyCombination.supportedKeys, id: \.code) { key in Text(key.name).tag(key.code) }
                }
                HStack(spacing: 14) {
                    modifier("Command", .command)
                    modifier("Shift", .shift)
                    modifier("Option", .option)
                    modifier("Control", .control)
                }
                Text("\(model.shortcutLabel) · press once to start, again to stop")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Text delivery") {
                Toggle("Insert at cursor when dictation stops", isOn: settingsBinding(\.automaticInsertion))
                Text("Uses Accessibility and, when needed, Paste. Paste briefly uses the clipboard and restores it if nothing else copied. If the destination changes or cannot accept text, a quiet indicator offers Review or Copy.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.settings.automaticInsertion && !model.permissions.accessibilityGranted {
                    Button("Enable Accessibility in System Settings…") { model.permissions.openAccessibilitySettings() }
                }
            }
            Section("Permissions") {
                LabeledContent("Microphone", value: model.permissions.microphoneStatus)
                LabeledContent("Accessibility", value: model.permissions.accessibilityGranted ? "Allowed" : "Needed for cursor insertion")
                HStack {
                    Button("Microphone settings…") { model.permissions.openMicrophoneSettings() }
                    Button("Refresh") { model.refreshPermissions() }
                }
            }
            Section {
                DisclosureGroup("Recording limits", isExpanded: $advanced) {
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
                }
            }
            if let notice = model.notice {
                Section { Label(notice, systemImage: "exclamationmark.triangle").font(.callout) }
            }
            Button("Reveal settings file") { model.revealSettings() }
                .font(.caption)
        }
        .formStyle(.grouped)
        .disabled(model.coordinator.phase.isActive)
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
    let stop: () -> Void
    let cancel: () -> Void
    let review: () -> Void
    let copy: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: session.phase == .recording ? "mic.fill" : "waveform")
                .foregroundStyle(session.phase == .recording ? Color.red : Color.accentColor)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.phase.isActive ? session.phase.title : session.failure != nil ? "Dictation interrupted" : session.deliveryResult?.outcome == .blocked ? "Insertion blocked" : "Transcript ready")
                    .font(.callout.weight(.medium)).lineLimit(1)
                if session.phase == .recording, let date = session.recordingStartedAt {
                    Text(date, style: .timer).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if !session.phase.isActive {
                    Text(session.failure ?? session.deliveryResult?.message ?? "Transcript ready")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .help(session.failure ?? session.deliveryResult?.message ?? "Transcript ready")
                } else if session.automaticallyStopped {
                    Text("Recording limit reached").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if session.phase == .recording { Button("Stop", action: stop).controlSize(.small) }
            if !session.phase.isActive {
                Button("Review", action: review).controlSize(.small)
                if !session.transcript.isEmpty { Button("Copy", action: copy).controlSize(.small) }
            }
            Button(action: session.phase.isActive ? cancel : dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help(session.phase.isActive ? "Cancel dictation" : "Dismiss")
                .accessibilityLabel(session.phase.isActive ? "Cancel dictation" : "Dismiss")
                .disabled(session.phase == .cancelling)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(width: 340, height: 64)
        .modifier(UtilityGlass())
    }
}
