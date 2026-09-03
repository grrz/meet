import AVFoundation
import Foundation

/// Errors thrown by `WavWriter`.
public enum WavWriterError: Error, CustomStringConvertible {
    /// `AVAudioConverter(from:to:)` returned nil for the given formats
    /// (e.g. an unsupported channel layout or sample rate combination).
    case converterCreationFailed(source: AVAudioFormat, target: AVAudioFormat)
    /// `write(_:)` was called while no converter is available — this can
    /// only happen after `updateSourceFormat` was given a format it could
    /// not build a converter for.
    case noConverter

    public var description: String {
        switch self {
        case .converterCreationFailed(let source, let target):
            return "WavWriter: could not create AVAudioConverter from \(source) to \(target)"
        case .noConverter:
            return "WavWriter: no audio converter is available (a previous updateSourceFormat call failed)"
        }
    }
}

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
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: Self.targetSampleRate,
                                          channels: 1, interleaved: true)!
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw WavWriterError.converterCreationFailed(source: sourceFormat, target: targetFormat)
        }
        self.targetFormat = targetFormat
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
        self.converter = converter
    }

    /// Device changes alter the source format mid-recording. Any audio still
    /// buffered inside the outgoing converter is drained and written before
    /// the converter is replaced, so the switch does not lose a tail of
    /// samples. If a converter for the new format cannot be built, the
    /// writer is left without a converter and subsequent `write(_:)` calls
    /// will throw `WavWriterError.noConverter` until a working format is
    /// supplied.
    public func updateSourceFormat(_ format: AVAudioFormat) {
        guard !closed else { return }
        if let oldConverter = converter {
            drainTail(of: oldConverter, context: "updateSourceFormat")
        }
        sourceFormat = format
        let newConverter = AVAudioConverter(from: format, to: targetFormat)
        converter = newConverter
        if newConverter == nil {
            fputs("WavWriter: failed to create converter for updated source format "
                  + "(sampleRate=\(format.sampleRate), channels=\(format.channelCount)); "
                  + "writes will throw until updateSourceFormat succeeds\n", stderr)
        }
    }

    public func write(_ buffer: AVAudioPCMBuffer) throws {
        guard !closed else { return }
        guard let converter else {
            throw WavWriterError.noConverter
        }

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
        if let converter {
            drainTail(of: converter, context: "finalize")
        }
        file.close()
    }

    /// Feeds `.endOfStream` to `converter` repeatedly, writing every chunk
    /// it produces, until it stops producing output or errors. This is the
    /// idiomatic AVAudioConverter drain loop: a single `.endOfStream` call
    /// is not guaranteed to flush everything the converter has buffered
    /// internally, so we keep pulling until it reports it is done.
    @discardableResult
    private func drainTail(of converter: AVAudioConverter, context: String) -> AVAudioFramePosition {
        var written: AVAudioFramePosition = 0
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 4096) else { break }
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if out.frameLength > 0 {
                do {
                    try file.write(from: out)
                    framesWritten += AVAudioFramePosition(out.frameLength)
                    written += AVAudioFramePosition(out.frameLength)
                } catch {
                    fputs("WavWriter: failed to write drained tail during \(context): \(error)\n", stderr)
                    break
                }
            }
            if status == .error || out.frameLength == 0 {
                break
            }
        }
        return written
    }
}
