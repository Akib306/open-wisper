import Foundation

public struct WhisperTranscriber: Sendable {
    public init() {}

    /// Hash-verify a pinned offline profile, run one short-lived worker, and remove its WAV.
    /// Cancellation throws CancellationError; all other engine failures are EngineError.
    /// elapsed is monotonic worker time, excluding artifact verification and workspace I/O.
    public func transcribe(audio: RecordedAudio, profileURL: URL, timeout: TimeInterval) async throws -> TranscriptionResult {
        try await transcribe(audio: audio, profileURL: profileURL, timeout: timeout, workspaceRoot: SessionWorkspace.defaultRoot)
    }

    /// Optional startup recovery. Active locked sessions and unrecognized entries are skipped.
    @discardableResult
    public static func recoverStaleSessions(olderThan age: TimeInterval = 86_400) throws -> Int {
        try SessionWorkspace.recoverStale(olderThan: age)
    }

    // Internal root injection keeps lifecycle tests isolated from real app sessions.
    func transcribe(audio: RecordedAudio, profileURL: URL, timeout: TimeInterval, workspaceRoot: URL) async throws -> TranscriptionResult {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0, timeout <= 3_600 else { throw EngineError.invalidTimeout }
        try Self.validateAudio(audio)
        let profile = try EngineManifest.loadValidated(from: profileURL)
        try Task.checkCancellation()
        let workspace = try SessionWorkspace(rootURL: workspaceRoot)
        // Creation and the very first write are inside the protected ownership lifetime.
        defer { try? workspace.cleanup() }
        try workspace.writeAudio(audio.wavData)
        let manifest = profile.manifest
        let arguments = manifest.decodeArguments + [
            "--threads", String(manifest.threads), "--processors", "1", "--language", manifest.language,
            "--model", profile.modelURL.path, "--file", workspace.audioURL.path
        ]
        let environment = [
            "PATH": "/usr/bin:/bin", "HOME": workspace.directoryURL.path,
            "TMPDIR": workspace.directoryURL.path, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
            "OMP_NUM_THREADS": String(manifest.threads), "VECLIB_MAXIMUM_THREADS": String(manifest.threads)
        ]
        let output = try await ProcessSupervisor().run(
            executable: profile.executableURL, arguments: arguments, directory: workspace.directoryURL,
            environment: environment, timeout: timeout
        )
        try Task.checkCancellation()
        guard let text = String(data: output.stdout, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 || ($0.value < 32 && ![9, 10, 13].contains($0.value)) || $0.value == 127 })
        else { throw EngineError.invalidOutput }
        // Whisper emits leading segment spacing and a terminal newline; preserve internal text.
        let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try workspace.cleanup()
        return TranscriptionResult(text: transcript, elapsed: output.elapsed, peakResidentBytes: output.peakResidentBytes)
    }

    private static func validateAudio(_ audio: RecordedAudio) throws {
        let data = audio.wavData
        guard audio.duration.isFinite, audio.duration > 0, audio.duration <= 300,
              data.count >= 44, data.count <= 9_665_536,
              data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8)
        else { throw EngineError.invalidAudio }
        func integer(_ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        guard integer(4, 4) == data.count - 8 else { throw EngineError.invalidAudio }
        var offset = 12
        var formatFound = false
        var samples: Int?
        while offset < data.count {
            guard offset <= data.count - 8 else { throw EngineError.invalidAudio }
            let size = integer(offset + 4, 4)
            let body = offset + 8
            guard size <= data.count - body else { throw EngineError.invalidAudio }
            let id = data[offset..<(offset + 4)]
            if id == Data("fmt ".utf8) {
                guard !formatFound, size >= 16, integer(body, 2) == 1,
                      integer(body + 2, 2) == 1, integer(body + 4, 4) == 16_000,
                      integer(body + 8, 4) == 32_000, integer(body + 12, 2) == 2,
                      integer(body + 14, 2) == 16 else { throw EngineError.invalidAudio }
                formatFound = true
            } else if id == Data("data".utf8) {
                guard samples == nil, size > 0, size % 2 == 0, size <= 9_600_000 else { throw EngineError.invalidAudio }
                samples = size / 2
            }
            offset = body + size + size % 2
        }
        guard offset == data.count, formatFound, let samples,
              abs(Double(samples) / 16_000 - audio.duration) <= 1.0 / 16_000 else { throw EngineError.invalidAudio }
    }
}
