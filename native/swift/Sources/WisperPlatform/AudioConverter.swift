import AVFAudio
import Foundation
import WisperCore

/// Queue-confined streaming conversion. This object is deliberately not
/// Sendable: its owner must call every method on the same serial capture queue.
/// Channels are averaged equally in Double, then clipped to [-1, 1]. Native
/// high-quality SRC runs on mono Float32; its filter overshoot is clipped again
/// before explicit signed-16 quantization. Non-finite input is a capture error.
final class PCM16AudioConverter {
    static let sampleRate = 16_000.0
    static let maximumDuration: TimeInterval = 300
    static let blockFrames = 4_096
    static let minimumDuration: TimeInterval = 0.02

    let inputSampleRate: Double
    let channelCount: Int
    private let maximumInputFrames: Int
    private let maximumOutputFrames: Int
    private let converter: AVAudioConverter
    private let feeder: AudioConverterFeeder
    private let output: AVAudioPCMBuffer
    private let quantized: UnsafeMutablePointer<Int16>
    private var wav = Data(count: 44)
    private(set) var inputFrameCount = 0
    private(set) var lastLevel: Float = 0
    private var finished: Result<RecordedAudio, WisperError>?

    init(inputSampleRate: Double, channelCount: Int,
         maximumDuration: TimeInterval = PCM16AudioConverter.maximumDuration) throws {
        guard inputSampleRate.isFinite, (8_000...192_000).contains(inputSampleRate),
              (1...32).contains(channelCount), maximumDuration.isFinite,
              maximumDuration >= Self.minimumDuration,
              maximumDuration <= Self.maximumDuration,
              let source = AVAudioFormat(standardFormatWithSampleRate: inputSampleRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let converter = AVAudioConverter(from: source, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target,
                                            frameCapacity: AVAudioFrameCount(Self.blockFrames)) else {
            throw WisperError.message("The microphone audio format is unsupported.")
        }
        self.inputSampleRate = inputSampleRate
        self.channelCount = channelCount
        self.maximumInputFrames = Int((inputSampleRate * maximumDuration).rounded(.down))
        self.maximumOutputFrames = Int((Self.sampleRate * maximumDuration).rounded(.down))
        self.converter = converter
        self.output = output
        self.feeder = try AudioConverterFeeder(format: source, capacity: Self.blockFrames)
        self.quantized = .allocate(capacity: Self.blockFrames)
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Normal
        // Normal priming synthesizes boundary zeros and compensates filter delay.
        // End-of-stream is still required to recover the final filter tail.
        converter.primeMethod = .normal
        converter.dither = false
        wav.reserveCapacity(44 + (maximumOutputFrames + Self.blockFrames) * 2)
    }

    deinit { quantized.deallocate() }

    /// Accepts borrowed interleaved samples only for this synchronous call.
    /// Larger offline fixtures are split internally, just like ring consumer reads.
    func append(interleaved samples: UnsafeBufferPointer<Float>, frameCount: Int) throws {
        guard finished == nil else { throw WisperError.message("Audio conversion has already finished.") }
        guard frameCount >= 0, frameCount <= samples.count / channelCount else {
            throw WisperError.message("The audio frame buffer is incomplete.")
        }
        guard frameCount <= maximumInputFrames - inputFrameCount else {
            throw WisperError.message("Recording reached the five-minute audio limit.")
        }
        guard frameCount > 0, let base = samples.baseAddress else { return }
        var offset = 0
        while offset < frameCount {
            let count = min(Self.blockFrames, frameCount - offset)
            var squares = 0.0
            for frame in 0..<count {
                var sum = 0.0
                for channel in 0..<channelCount {
                    let value = base[(offset + frame) * channelCount + channel]
                    guard value.isFinite else {
                        let error = WisperError.message("The microphone supplied invalid audio samples.")
                        finished = .failure(error)
                        throw error
                    }
                    sum += Double(value)
                }
                let mono = min(1, max(-1, sum / Double(channelCount)))
                feeder.samples[frame] = Float(mono)
                squares += mono * mono
            }
            lastLevel = Float((squares / Double(count)).squareRoot())
            feeder.begin(frameCount: count)
            inputFrameCount += count
            do { try pump(endOfStream: false) }
            catch {
                let failure = (error as? WisperError) ?? .message("Audio conversion failed.")
                finished = .failure(failure)
                throw failure
            }
            offset += count
        }
    }

    /// Idempotent. No reset/reuse across sessions; finalization drains the native
    /// converter to EOS once, then trims only its synthesized trailing padding.
    func finish() throws -> RecordedAudio {
        if let finished { return try finished.get() }
        do {
            guard inputFrameCount >= Int((inputSampleRate * Self.minimumDuration).rounded(.up)) else {
                throw WisperError.message("Recording is too short. Record at least 20 milliseconds of audio.")
            }
            feeder.endOfStream = true
            try pump(endOfStream: true)
            // A fractional output sample cannot be represented. Keep floor(N *
            // outputRate / inputRate), so duration differs by less than 1 sample.
            let frameCount = Int((Double(inputFrameCount) * Self.sampleRate / inputSampleRate).rounded(.down))
            let pcmBytes = frameCount * 2
            guard frameCount > 0, wav.count - 44 >= pcmBytes else {
                throw WisperError.message("Audio conversion ended before all recorded frames were produced.")
            }
            if wav.count > pcmBytes + 44 { wav.removeSubrange((pcmBytes + 44)..<wav.count) }
            wav.replaceSubrange(0..<44, with: Self.wavHeader(pcmBytes: pcmBytes))
            let result = RecordedAudio(wavData: wav, duration: Double(frameCount) / Self.sampleRate)
            finished = .success(result)
            return result
        } catch {
            let failure = (error as? WisperError) ?? .message("Audio finalization failed.")
            finished = .failure(failure)
            throw failure
        }
    }

    private func pump(endOfStream: Bool) throws {
        let feeder = feeder
        // Each call consumes at most one 4096-frame source block (8192 output
        // frames at the smallest supported input rate), plus native filter tail.
        // Bound defective converter behavior instead of spinning indefinitely.
        for _ in 0..<32 {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { requested, status in
                feeder.next(requested: requested, status: status)
            }
            if status == .error || error != nil {
                throw WisperError.message("Native audio conversion failed: \(error?.localizedDescription ?? "unknown converter error")")
            }
            try appendOutput()
            switch status {
            case .haveData:
                continue
            case .inputRanDry:
                guard !endOfStream, feeder.remainingFrames == 0 else {
                    throw WisperError.message("Audio conversion did not finish its input.")
                }
                return
            case .endOfStream:
                guard endOfStream else { throw WisperError.message("Audio conversion ended unexpectedly.") }
                return
            case .error:
                throw WisperError.message("Native audio conversion failed.")
            @unknown default:
                throw WisperError.message("Native audio conversion returned an unknown state.")
            }
        }
        throw WisperError.message("Native audio conversion stopped making bounded progress.")
    }

    private func appendOutput() throws {
        let count = Int(output.frameLength)
        guard count > 0 else { return }
        guard let source = output.floatChannelData?[0],
              count <= Self.blockFrames,
              (wav.count - 44) / 2 + count <= maximumOutputFrames + Self.blockFrames else {
            throw WisperError.message("Converted audio exceeded its memory limit.")
        }
        for index in 0..<count {
            guard source[index].isFinite else { throw WisperError.message("Native audio conversion produced invalid samples.") }
            let sample = min(1, max(-1, Double(source[index])))
            let integer = Int16((sample * (sample < 0 ? 32_768 : 32_767)).rounded())
            quantized[index] = integer.littleEndian
        }
        wav.append(UnsafeRawPointer(quantized).assumingMemoryBound(to: UInt8.self), count: count * 2)
    }

    private static func wavHeader(pcmBytes: Int) -> Data {
        var header = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { header.append(contentsOf: $0) }
        }
        header.append(contentsOf: "RIFF".utf8)
        append(UInt32(pcmBytes + 36))
        header.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))  // PCM
        append(UInt16(1))  // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate) * 2)
        append(UInt16(2))
        append(UInt16(16))
        header.append(contentsOf: "data".utf8)
        append(UInt32(pcmBytes))
        return header
    }
}

/// Narrow Sendable bridge for AVAudioConverter's @Sendable input block. The
/// converter calls the block synchronously during convert(to:...), and that
/// call and all mutations are confined to one owner queue. Neither this object
/// nor its buffers escape the converter or get used by the realtime audio tap.
private final class AudioConverterFeeder: @unchecked Sendable {
    let samples: UnsafeMutablePointer<Float>
    private let buffer: AVAudioPCMBuffer
    private var frameCount = 0
    private var offset = 0
    var endOfStream = false
    var remainingFrames: Int { frameCount - offset }

    init(format: AVAudioFormat, capacity: Int) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw WisperError.message("Unable to allocate an audio conversion buffer.")
        }
        self.buffer = buffer
        samples = .allocate(capacity: capacity)
    }

    deinit { samples.deallocate() }

    func begin(frameCount: Int) {
        self.frameCount = frameCount
        offset = 0
    }

    func next(requested: AVAudioPacketCount,
              status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard remainingFrames > 0, requested > 0 else {
            status.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
        let count = min(remainingFrames, Int(requested), Int(buffer.frameCapacity))
        buffer.floatChannelData![0].update(from: samples + offset, count: count)
        buffer.frameLength = AVAudioFrameCount(count)
        offset += count
        status.pointee = .haveData
        return buffer
    }
}
