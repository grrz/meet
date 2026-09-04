import AVFoundation
import Foundation

/// Errors thrown by `AudioCompressor`.
public enum AudioCompressorError: Error, LocalizedError {
    /// The source opened but yielded no audio frames. Compression is the one
    /// path allowed to delete recorded audio, and only after it has verifiably
    /// re-encoded it — so a zero-frame decode must abort instead.
    case noAudioDecoded(URL)
    /// The encoder produced an empty file.
    case emptyOutput(URL)

    public var errorDescription: String? {
        switch self {
        case .noAudioDecoded(let url):
            """
            Refusing to compress \(url.lastPathComponent): its header opened \
            but no audio frames could be decoded. The original file is \
            untouched — inspect it before retrying.
            """
        case .emptyOutput(let url):
            "Compressing \(url.lastPathComponent) produced an empty file; the original is untouched."
        }
    }
}

public enum AudioCompressor {
    /// Re-encodes `wav` as AAC at `m4a` and deletes `wav` — but only once the
    /// re-encode is verified, since this is the sole path permitted to remove
    /// recorded audio.
    public static func compress(wav: URL, to m4a: URL) throws {
        let input = try AVAudioFile(forReading: wav)
        let processingFormat = input.processingFormat

        try? FileManager.default.removeItem(at: m4a)
        let output = try AVAudioFile(
            forWriting: m4a,
            settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: processingFormat.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
            ]
        )

        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: processingFormat,
                                            frameCapacity: chunk) else {
            try? FileManager.default.removeItem(at: m4a)
            throw CocoaError(.fileReadUnknown)
        }
        var framesRead: AVAudioFramePosition = 0
        do {
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                framesRead += AVAudioFramePosition(buffer.frameLength)
                try output.write(from: buffer)
            }
            output.close()
        } catch {
            try? FileManager.default.removeItem(at: m4a)
            throw error
        }

        // A stale-header WAV (see WavHeaderRepair) opens fine and reports zero
        // frames. Encoding that yields a ~557-byte container of pure silence,
        // which sails past the size check below — and deleting the WAV then
        // destroys the recording. Never delete audio we did not actually read.
        guard framesRead > 0 else {
            try? FileManager.default.removeItem(at: m4a)
            throw AudioCompressorError.noAudioDecoded(wav)
        }

        let size = (try FileManager.default
            .attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: m4a)
            throw AudioCompressorError.emptyOutput(wav)
        }
        try FileManager.default.removeItem(at: wav)
    }
}
