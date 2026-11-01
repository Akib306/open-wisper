import AVFAudio
import CWisperAudio
import Foundation
import Testing
@testable import WisperPlatform
import WisperCore

@Suite("Offline audio conversion")
struct AudioConverterTests {
    func convert(_ samples: [Float], rate: Double, channels: Int = 1, chunk: Int = 1_024) throws -> RecordedAudio {
        let converter = try PCM16AudioConverter(inputSampleRate: rate, channelCount: channels)
        let frames = samples.count / channels
        try samples.withUnsafeBufferPointer { buffer in
            var offset = 0
            while offset < frames {
                let count = min(chunk, frames - offset)
                try converter.append(interleaved: UnsafeBufferPointer(rebasing: buffer[(offset * channels)..<((offset + count) * channels)]), frameCount: count)
                offset += count
            }
        }
        let audio = try converter.finish()
        #expect(try converter.finish().wavData == audio.wavData)
        return audio
    }

    func pcm(_ data: Data) -> [Double] {
        stride(from: 44, to: data.count, by: 2).map {
            Double(Int16(bitPattern: UInt16(data[$0]) | UInt16(data[$0 + 1]) << 8)) / 32_768
        }
    }

    @Test(arguments: [44_100.0, 48_000.0]) func durationHeaderAndFinalPartialBlock(rate: Double) throws {
        let count = Int(rate) + 113
        let samples = (0..<count).map { Float(sin(2 * .pi * 440 * Double($0) / rate) * 0.5) }
        let audio = try convert(samples, rate: rate, chunk: 997)
        let expected = Int((Double(count) * 16_000 / rate).rounded(.down))
        #expect(audio.wavData.count == 44 + expected * 2)
        #expect(audio.duration == Double(expected) / 16_000)
        #expect(String(data: audio.wavData.prefix(4), encoding: .ascii) == "RIFF")
        #expect(Array(audio.wavData[22..<24]) == [1, 0])
        #expect(Array(audio.wavData[24..<28]) == [0x80, 0x3e, 0, 0])
        #expect(pcm(audio.wavData).suffix(20).contains { abs($0) > 0.1 })
    }

    @Test func stereoDownmixAndSilence() throws {
        let opposite = (0..<4_800).flatMap { index -> [Float] in
            let sample = Float(sin(2 * .pi * 900 * Double(index) / 48_000))
            return [sample, -sample]
        }
        let cancelled = try convert(opposite, rate: 48_000, channels: 2)
        #expect(pcm(cancelled.wavData).allSatisfy { abs($0) <= 1 / 32_768 })
        let silent = try convert([Float](repeating: 0, count: 4_800), rate: 48_000)
        #expect(pcm(silent.wavData).allSatisfy { $0 == 0 })
    }

    @Test func clippingAndInvalidInput() throws {
        let positive = try convert([Float](repeating: 4, count: 1_600), rate: 16_000)
        #expect(pcm(positive.wavData).dropFirst(100).dropLast(100).allSatisfy { $0 > 0.99 && $0 <= 1 })
        let negative = try convert([Float](repeating: -4, count: 1_600), rate: 16_000)
        #expect(pcm(negative.wavData).dropFirst(100).dropLast(100).allSatisfy { $0 < -0.99 && $0 >= -1 })
        #expect(throws: (any Error).self) { try convert([Float.nan], rate: 16_000) }
        #expect(throws: (any Error).self) { try convert([], rate: 16_000) }
    }

    @Test func antiAliasFilterRejectsAboveNyquist() throws {
        func rms(_ frequency: Double) throws -> Double {
            let input = (0..<48_000).map { Float(sin(2 * .pi * frequency * Double($0) / 48_000) * 0.8) }
            let output = pcm(try convert(input, rate: 48_000).wavData).dropFirst(1_000).dropLast(1_000)
            return (output.reduce(0) { $0 + $1 * $1 } / Double(output.count)).squareRoot()
        }
        let passband = try rms(1_000)
        let stopband = try rms(12_000)
        #expect(passband > 0.5)
        #expect(stopband < passband * 0.01)
    }

    @Test func durationBoundRejectsExcessAudio() throws {
        let converter = try PCM16AudioConverter(inputSampleRate: 16_000, channelCount: 1, maximumDuration: 0.1)
        let samples = [Float](repeating: 0, count: 1_601)
        #expect(throws: (any Error).self) {
            try samples.withUnsafeBufferPointer { try converter.append(interleaved: $0, frameCount: $0.count) }
        }
    }
}

@Suite("Bounded realtime audio handoff")
struct AudioRingTests {
    func write(_ samples: [Float], to ring: OpaquePointer, channels: Int = 1) -> Bool {
        samples.withUnsafeBufferPointer { input in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(input.count * MemoryLayout<Float>.size), mData: UnsafeMutableRawPointer(mutating: input.baseAddress)))
            return wisper_audio_ring_write(ring, &buffers, UInt32(samples.count / channels))
        }
    }

    @Test func orderingWrappingAndFinalDrain() throws {
        let ring = try #require(wisper_audio_ring_create(8, 1, 100))
        defer { wisper_audio_ring_destroy(ring) }
        #expect(write([0, 1, 2, 3, 4, 5], to: ring))
        var output = [Float](repeating: -1, count: 8)
        #expect(wisper_audio_ring_read(ring, &output, 4) == 4)
        #expect(Array(output.prefix(4)) == [0, 1, 2, 3])
        #expect(write([6, 7, 8, 9, 10], to: ring))
        wisper_audio_ring_close(ring)
        #expect(wisper_audio_ring_producer_idle(ring))
        #expect(!write([11], to: ring))
        #expect(wisper_audio_ring_read(ring, &output, 8) == 7)
        #expect(Array(output.prefix(7)) == [4, 5, 6, 7, 8, 9, 10])
        #expect(wisper_audio_ring_read(ring, &output, 8) == 0)
    }

    @Test func overflowIsStickyAndResetRequiresClosure() throws {
        let ring = try #require(wisper_audio_ring_create(4, 1, 100))
        defer { wisper_audio_ring_destroy(ring) }
        #expect(!wisper_audio_ring_reset(ring))
        #expect(write([1, 2, 3, 4], to: ring))
        #expect(!write([5], to: ring))
        #expect(wisper_audio_ring_error(ring) == WisperAudioRingErrorOverflow)
        #expect(!write([6], to: ring))
        #expect(wisper_audio_ring_reset(ring))
        #expect(wisper_audio_ring_error(ring) == WisperAudioRingErrorNone)
        #expect(write([8], to: ring))
    }

    @Test func stereoAndDurationLimit() throws {
        let ring = try #require(wisper_audio_ring_create(8, 2, 3))
        defer { wisper_audio_ring_destroy(ring) }
        #expect(write([1, -1, 2, -2, 3, -3], to: ring, channels: 2))
        var output = [Float](repeating: 0, count: 6)
        #expect(wisper_audio_ring_read(ring, &output, 3) == 3)
        #expect(output == [1, -1, 2, -2, 3, -3])
        #expect(!write([4, -4], to: ring, channels: 2))
        #expect(wisper_audio_ring_error(ring) == WisperAudioRingErrorDurationLimit)
    }
}
