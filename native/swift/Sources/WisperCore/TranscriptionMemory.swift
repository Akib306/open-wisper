import Foundation

public struct TranscriptionMemory: Sendable, Equatable {
    public let peakResidentBytes: UInt64?

    public init(peakResidentBytes: UInt64?) {
        self.peakResidentBytes = peakResidentBytes
    }

    public var formattedPeak: String {
        guard let peakResidentBytes, peakResidentBytes > 0, peakResidentBytes <= UInt64(Int64.max) else {
            return "Unavailable"
        }
        return ByteCountFormatter.string(fromByteCount: Int64(peakResidentBytes), countStyle: .memory)
    }
}
