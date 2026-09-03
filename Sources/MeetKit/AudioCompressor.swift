import AVFoundation
import Foundation

public enum AudioCompressor {
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
        do {
            while input.framePosition < input.length {
                try input.read(into: buffer)
                if buffer.frameLength == 0 { break }
                try output.write(from: buffer)
            }
            output.close()
        } catch {
            try? FileManager.default.removeItem(at: m4a)
            throw error
        }

        let size = (try FileManager.default
            .attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: m4a)
            throw CocoaError(.fileWriteUnknown)
        }
        try FileManager.default.removeItem(at: wav)
    }
}
