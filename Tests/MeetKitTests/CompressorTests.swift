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

    func testCompressWithInvalidWavLeavesSourceAndCleansM4a() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create a non-audio "WAV" file (junk data).
        let junkWav = dir.appendingPathComponent("junk.wav")
        try "this is not audio data".write(to: junkWav, atomically: true, encoding: .utf8)

        let m4a = dir.appendingPathComponent("output.m4a")

        // Attempt compress; should throw.
        XCTAssertThrowsError(try AudioCompressor.compress(wav: junkWav, to: m4a))

        // Verify source junk file still exists (not deleted on error).
        XCTAssertTrue(FileManager.default.fileExists(atPath: junkWav.path))

        // Verify no partial m4a remains.
        XCTAssertFalse(FileManager.default.fileExists(atPath: m4a.path))
    }

    /// The critical data-loss case: a WAV whose header is structurally valid
    /// but declares zero frames (a recording killed before its header was
    /// finalized). It opens, decodes nothing, and encodes to a tiny silent
    /// container whose size is comfortably > 0 — so the size check alone let
    /// the WAV be deleted. Compression must refuse outright.
    func testCompressRefusesWavWithZeroDecodedFrames() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Canonical 44-byte header, valid in every field, data chunk empty.
        var header = Data()
        func tag(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        tag("RIFF"); u32(36); tag("WAVE")
        tag("fmt "); u32(16)
        u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16)
        tag("data"); u32(0)

        let wav = dir.appendingPathComponent("empty.wav")
        try header.write(to: wav)

        // Precondition: it really does open and read as zero frames.
        XCTAssertEqual(try AVAudioFile(forReading: wav).length, 0)

        let m4a = dir.appendingPathComponent("empty.m4a")
        XCTAssertThrowsError(try AudioCompressor.compress(wav: wav, to: m4a)) { error in
            guard case AudioCompressorError.noAudioDecoded = error else {
                return XCTFail("expected noAudioDecoded, got \(error)")
            }
        }

        // Audio is sacred: the source survives and no stub m4a is left.
        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertEqual(try Data(contentsOf: wav), header)
        XCTAssertFalse(FileManager.default.fileExists(atPath: m4a.path))
    }
}
