import AVFoundation
import Foundation

/// Streams AVAudioPCMBuffers of any source format into a 48 kHz mono 16-bit WAV.
/// Not thread-safe by design: each recorder owns one writer and calls it from
/// a single audio callback thread. finalize() may be called from another thread
/// only after the callback source is stopped.
public final class WavWriter {
    public static let targetSampleRate: Double = 48_000

    private let file: AVAudioFile
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat
    private var closed = false
    public private(set) var framesWritten: AVAudioFramePosition = 0

    public var durationSeconds: Double {
        Double(framesWritten) / Self.targetSampleRate
    }

    public init(url: URL, sourceFormat: AVAudioFormat) throws {
        self.targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: Self.targetSampleRate,
                                          channels: 1, interleaved: true)!
        self.file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: Self.targetSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ],
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )
        self.sourceFormat = sourceFormat
        self.converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
    }

    public func updateSourceFormat(_ format: AVAudioFormat) {
        sourceFormat = format
        converter = AVAudioConverter(from: format, to: targetFormat)
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard !closed else { return }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: capacity) else { return }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: out, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard status != .error, out.frameLength > 0 else { return }

        try file.write(from: out)
        framesWritten += AVAudioFramePosition(out.frameLength)
    }

    public func finalize() {
        guard !closed else { return }
        closed = true
        // Drain converter tail.
        if let converter,
           let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) {
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if status == .haveData, out.frameLength > 0, (try? file.write(from: out)) != nil {
                framesWritten += AVAudioFramePosition(out.frameLength)
            }
        }
        file.close()
    }
}
