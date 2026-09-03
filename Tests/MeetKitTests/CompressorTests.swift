import XCTest
import AVFoundation
@testable import MeetKit

final class CompressorTests: XCTestCase {
    func testCompressProducesM4aAndDeletesWav() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Build a 0.5 s WAV via WavWriter.
        let wav = dir.appendingPathComponent("track.wav")
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let writer = try WavWriter(url: wav, sourceFormat: fmt)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 24000)!
        buf.frameLength = 24000
        for i in 0..<24000 {
            buf.floatChannelData![0][i] = Float(sin(Double(i) * 0.05) * 0.4)
        }
        try writer.write(buf)
        writer.finalize()

        let m4a = dir.appendingPathComponent("track.m4a")
        try AudioCompressor.compress(wav: wav, to: m4a)

        XCTAssertFalse(FileManager.default.fileExists(atPath: wav.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: m4a.path)
        XCTAssertGreaterThan(attrs[.size] as! Int, 0)
        let readBack = try AVAudioFile(forReading: m4a)
        XCTAssertEqual(Double(readBack.length) / readBack.fileFormat.sampleRate,
                       0.5, accuracy: 0.1)
    }
}
