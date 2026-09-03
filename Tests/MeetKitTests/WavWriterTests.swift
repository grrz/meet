import XCTest
import AVFoundation
@testable import MeetKit

final class WavWriterTests: XCTestCase {
    /// A format `AVAudioFormat(streamDescription:)` will construct but
    /// `AVAudioConverter(from:to:)` refuses to build a converter for (zero
    /// channels) — used to exercise the "converter creation failed" paths
    /// without needing to mock AVFoundation.
    func makeUnconvertibleFormat() -> AVAudioFormat {
        var desc = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 0,
            mFramesPerPacket: 1,
            mBytesPerFrame: 0,
            mChannelsPerFrame: 0,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        return AVAudioFormat(streamDescription: &desc)!
    }

    func makeSine(format: AVAudioFormat, frames: AVAudioFrameCount,
                  freq: Double = 440) -> AVAudioPCMBuffer {
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buf.frameLength = frames
        let sr = format.sampleRate
        for ch in 0..<Int(format.channelCount) {
            let data = buf.floatChannelData![ch]
            for i in 0..<Int(frames) {
                data[i] = Float(sin(2 * .pi * freq * Double(i) / sr) * 0.5)
            }
        }
        return buf
    }

    func testWritesResampledMonoWav() throws {
        // Source: 44.1 kHz stereo float — a typical mic/tap format.
        let source = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url, sourceFormat: source)
        for _ in 0..<10 {
            try writer.write(makeSine(format: source, frames: 4410)) // 0.1 s each
        }
        writer.finalize()

        // ~1 second of source audio -> ~48000 frames at 48 kHz (converter may
        // hold back a few frames of latency; allow 2% tolerance).
        XCTAssertEqual(Double(writer.framesWritten), 48000, accuracy: 48000 * 0.02)
        XCTAssertEqual(writer.durationSeconds, 1.0, accuracy: 0.02)

        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBack.fileFormat.sampleRate, 48000)
        XCTAssertEqual(readBack.fileFormat.channelCount, 1)
        XCTAssertEqual(Double(readBack.length), Double(writer.framesWritten), accuracy: 16)
    }

    func testSourceFormatChangeMidStream() throws {
        let a = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let b = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url, sourceFormat: a)
        try writer.write(makeSine(format: a, frames: 4410))
        writer.updateSourceFormat(b)
        try writer.write(makeSine(format: b, frames: 4800))
        writer.finalize()

        XCTAssertEqual(writer.durationSeconds, 0.2, accuracy: 0.02)
    }

    func testSourceFormatChangeMidStreamPreservesTail() throws {
        // A longer stream on each side of the switch than
        // testSourceFormatChangeMidStream, so the fixed per-switch converter
        // latency is a small fraction of the total instead of being swamped
        // by single-buffer rounding noise. This isolates whether
        // updateSourceFormat is dropping the outgoing converter's buffered
        // tail rather than just measuring general conversion slop.
        let a = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let b = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url, sourceFormat: a)
        for _ in 0..<20 {
            try writer.write(makeSine(format: a, frames: 4410)) // 20 x 0.1s = 2.0s
        }
        writer.updateSourceFormat(b)
        for _ in 0..<20 {
            try writer.write(makeSine(format: b, frames: 4800)) // 20 x 0.1s = 2.0s
        }
        writer.finalize()

        // Total source audio is exactly 4.0s. updateSourceFormat must drain
        // the outgoing converter's internal buffer before replacing it, or
        // that tail is silently lost at every format switch.
        XCTAssertEqual(writer.durationSeconds, 4.0, accuracy: 4.0 * 0.005)
    }

    func testInitThrowsWhenConverterCannotBeCreated() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try WavWriter(url: url, sourceFormat: makeUnconvertibleFormat())) { error in
            guard case WavWriterError.converterCreationFailed = error else {
                return XCTFail("expected converterCreationFailed, got \(error)")
            }
        }
        // No half-created file should be left behind.
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testWriteThrowsAfterFailedUpdateSourceFormat() throws {
        let a = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url, sourceFormat: a)
        try writer.write(makeSine(format: a, frames: 4410)) // succeeds, converter healthy

        writer.updateSourceFormat(makeUnconvertibleFormat()) // fails to build a new converter

        XCTAssertThrowsError(try writer.write(makeSine(format: a, frames: 4410))) { error in
            guard case WavWriterError.noConverter = error else {
                return XCTFail("expected noConverter, got \(error)")
            }
        }
        writer.finalize()
    }
}
