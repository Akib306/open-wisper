import Testing
@testable import WisperCore

struct TranscriptionMemoryTests {
    @Test(arguments: [nil, UInt64(0), UInt64.max])
    func missingOrInvalidMeasurementsAreNotDisplayedAsZero(bytes: UInt64?) {
        #expect(TranscriptionMemory(peakResidentBytes: bytes).formattedPeak == "Unavailable")
    }

    @Test func measuredBytesHaveAReadableUnit() {
        let reading = TranscriptionMemory(peakResidentBytes: 128 * 1_024 * 1_024)
        #expect(reading.formattedPeak.contains("128"))
        #expect(reading.formattedPeak.contains("MB"))
    }
}
