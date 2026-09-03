import XCTest
import AVFoundation
@testable import MeetKit

final class WavWriterTests: XCTestCase {
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
}
