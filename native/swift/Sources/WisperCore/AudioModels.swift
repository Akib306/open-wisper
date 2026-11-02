import Foundation

/// Normalized mono, 16 kHz, signed 16-bit little-endian PCM WAV.
public struct RecordedAudio: Sendable {
    public let wavData: Data
    public let duration: TimeInterval

    public init(wavData: Data, duration: TimeInterval) {
        self.wavData = wavData
        self.duration = duration
    }

    /// Parse RIFF chunks rather than assuming every producer writes a 44-byte header.
    public init(wavData data: Data) throws {
        guard data.count >= 44, data.count <= 9_665_536,
              data.prefix(4) == Data("RIFF".utf8), data[8..<12] == Data("WAVE".utf8) else { throw EngineError.invalidAudio }
        func integer(_ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        guard integer(4, 4) == data.count - 8 else { throw EngineError.invalidAudio }
        var offset = 12
        var formatFound = false
        var samples: Int?
        while offset < data.count {
            guard offset <= data.count - 8 else { throw EngineError.invalidAudio }
            let size = integer(offset + 4, 4), body = offset + 8
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
        guard offset == data.count, formatFound, let samples else { throw EngineError.invalidAudio }
        self.init(wavData: data, duration: Double(samples) / 16_000)
    }
}

public struct TranscriptionResult: Sendable {
    public let text: String
    public let elapsed: TimeInterval
    public let peakResidentBytes: UInt64?

    public init(text: String, elapsed: TimeInterval, peakResidentBytes: UInt64? = nil) {
        self.text = text
        self.elapsed = elapsed
        self.peakResidentBytes = peakResidentBytes
    }
}

public enum WisperError: Error, LocalizedError, Sendable, Equatable {
    case message(String)

    public var errorDescription: String? {
        switch self { case .message(let message): message }
    }
}
