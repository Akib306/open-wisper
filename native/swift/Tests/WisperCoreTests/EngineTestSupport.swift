import CryptoKit
import Darwin
import Foundation
@testable import WisperCore

final class EngineFixture: @unchecked Sendable {
    let root: URL
    let executable: URL
    let model: URL
    let profile: URL
    let sessions: URL

    init(script: String = "#!/bin/sh\nprintf 'fixture transcript\\n'\n") throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("Engine fixture \(UUID().uuidString)", isDirectory: true)
        executable = root.appendingPathComponent("worker with spaces")
        model = root.appendingPathComponent("model with spaces.bin")
        profile = root.appendingPathComponent("profile.json")
        sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("original test fixture; not model weights".utf8).write(to: model)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: model.path)
        try writeManifest()
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    static func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func manifest() throws -> [String: Any] {
        let flags = [
            "CMAKE_BUILD_TYPE": "Release", "BUILD_SHARED_LIBS": "OFF", "GGML_CPU": "ON",
            "GGML_BACKEND_DL": "OFF", "GGML_METAL": "OFF", "GGML_CUDA": "OFF", "WHISPER_COREML": "OFF",
            "WHISPER_OPENVINO": "OFF", "WHISPER_CURL": "OFF", "GGML_ACCELERATE": "ON", "GGML_BLAS": "ON",
            "GGML_HIP": "OFF", "GGML_VULKAN": "OFF", "GGML_SYCL": "OFF", "GGML_RPC": "OFF",
            "GGML_OPENCL": "OFF", "GGML_WEBGPU": "OFF", "GGML_MUSA": "OFF"
        ]
        return [
            "schemaVersion": 1, "engine": "whisper.cpp", "sourceVersion": "v1.8.1", "sourceCommit": EngineManifest.pinnedCommit,
            "executable": ["path": executable.lastPathComponent, "sha256": try Self.digest(executable)],
            "model": ["path": model.lastPathComponent, "sha256": try Self.digest(model), "name": "tiny.en-q5_1",
                      "license": "MIT", "licenseURL": "https://github.com/openai/whisper/blob/main/LICENSE"],
            "architecture": EngineManifest.hostArchitecture, "buildFlags": flags.keys.sorted().map { "-D\($0)=\(flags[$0]!)" },
            "threads": 4, "acceleration": "cpu-accelerate", "decodeArguments": EngineManifest.decodingArguments,
            "language": "en", "residency": "short-lived",
            "provenance": ["kind": "operator-attested", "evidence": ["original-test-fixture": try Self.digest(executable)],
                           "limitations": "Original subprocess fixture, not a real inference engine."]
        ]
    }

    func writeManifest(_ modify: (inout [String: Any]) -> Void = { _ in }) throws {
        var value = try manifest()
        modify(&value)
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: profile)
    }

    func run(arguments: [String] = [], timeout: TimeInterval = 3, limit: Int = 1_048_576) async throws -> ProcessOutput {
        try await ProcessSupervisor().run(executable: executable, arguments: arguments, directory: root,
                                          environment: ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"],
                                          timeout: timeout, stdoutLimit: limit, stderrLimit: limit)
    }

    func transcribe(timeout: TimeInterval = 3) async throws -> TranscriptionResult {
        try await WhisperTranscriber().transcribe(audio: Self.audio(), profileURL: profile, timeout: timeout, workspaceRoot: sessions)
    }

    func sessionsAreEmpty() throws -> Bool {
        if !FileManager.default.fileExists(atPath: sessions.path) { return true }
        return try FileManager.default.contentsOfDirectory(atPath: sessions.path).isEmpty
    }

    static func audio() -> RecordedAudio {
        let samples = 1_600
        var data = Data("RIFF".utf8)
        func append(_ value: Int, bytes: Int) { for index in 0..<bytes { data.append(UInt8((value >> (index * 8)) & 0xff)) } }
        append(36 + samples * 2, bytes: 4)
        data.append(Data("WAVEfmt ".utf8)); append(16, bytes: 4); append(1, bytes: 2); append(1, bytes: 2)
        append(16_000, bytes: 4); append(32_000, bytes: 4); append(2, bytes: 2); append(16, bytes: 2)
        data.append(Data("data".utf8)); append(samples * 2, bytes: 4); data.append(Data(repeating: 0, count: samples * 2))
        return RecordedAudio(wavData: data, duration: 0.1)
    }

    func waitForFile(_ name: String) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) {
            guard clock.now < deadline else { throw EngineError.timedOut }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
