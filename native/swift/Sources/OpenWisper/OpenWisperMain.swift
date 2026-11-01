import AppKit
import Foundation
import SwiftUI
import WisperCore
import WisperPlatform

@main struct OpenWisperMain {
    @MainActor static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let profile = value(after: "--profile").map { URL(fileURLWithPath: $0) }
        do {
            if arguments.contains("--help") {
                print("""
                Open Wisper — native, local macOS dictation

                  OpenWisper [--profile /absolute/path/manifest.json]
                  OpenWisper --check-delivery
                  OpenWisper --check-profile --profile /path/manifest.json
                  OpenWisper --transcribe-wav /path/audio.wav --profile /path/manifest.json
                  OpenWisper --render-preview /path/preview.png [--preview-settings]

                The CLI never requests microphone or Accessibility permission.
                --transcribe-wav requires mono 16 kHz signed 16-bit PCM WAV and prints the transcript.
                Use the packaged .app for microphone capture and a stable permission identity.
                """)
                return
            }
            if arguments == ["--check-delivery"] {
                // Read-only: no recorder, hotkey, prompt, clipboard, or insertion.
                let settings = try SettingsStore().load()
                let report: DeliveryReadinessReport
                if let running = await DeliveryDiagnostics.queryRunningApp() { report = running }
                else {
                    report = DeliveryDiagnostics.report(automaticInsertion: settings.automaticInsertion,
                        source: "standalone CLI; macOS may use the launching terminal's permission identity")
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
                let data = try encoder.encode(report)
                print(String(decoding: data, as: UTF8.self))
                return
            }
            if arguments.contains("--check-profile") {
                guard let profile else { throw WisperError.message("Pass --profile /path/to/manifest.json.") }
                let description = try await Task.detached { try EngineProfileCheck.check(profile) }.value
                print(description)
                return
            }
            if let path = value(after: "--transcribe-wav") {
                guard let profile else { throw WisperError.message("Pass --profile /path/to/manifest.json.") }
                let audio = try readWAV(URL(fileURLWithPath: path))
                let result = try await WhisperTranscriber().transcribe(audio: audio, profileURL: profile, timeout: 120)
                print(result.text)
                return
            }
            if let path = value(after: "--render-preview") {
                try renderPreview(to: URL(fileURLWithPath: path), settings: arguments.contains("--preview-settings"))
                return
            }
            guard arguments.isEmpty || (arguments.count == 2 && arguments[0] == "--profile" && profile != nil) else {
                throw WisperError.message("Unknown or incomplete arguments. Run OpenWisper --help.")
            }
            guard let instanceLock = try ApplicationInstanceLock.acquire() else {
                DistributedNotificationCenter.default().postNotificationName(AppDelegate.reopenNotification,
                    object: nil, userInfo: nil, deliverImmediately: true)
                return
            }
            let app = NSApplication.shared
            let delegate = AppDelegate(profileURL: profile)
            app.delegate = delegate
            withExtendedLifetime((delegate, instanceLock)) { app.run() }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static func readWAV(_ url: URL) throws -> RecordedAudio {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size >= 44, size <= 9_665_536 else { throw WisperError.message("Choose a PCM WAV no longer than five minutes.") }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try RecordedAudio(wavData: file.read(upToCount: 9_665_537) ?? Data())
    }

    @MainActor private static func renderPreview(to url: URL, settings: Bool) throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let model = AppModel(preview: true)
        model.settingsOpen = settings
        let size = NSSize(width: 500, height: settings ? 760 : 560)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let view = NSHostingView(rootView: MainView(model: model, session: model.coordinator))
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw WisperError.message("Couldn’t create the UI preview bitmap.") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw WisperError.message("Couldn’t encode the UI preview.") }
        try png.write(to: url)
        window.close()
    }
}
