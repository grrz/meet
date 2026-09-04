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

    /// `MicRecorder` drops a straggler buffer from a discarded engine by
    /// comparing it against the writer's current source format, so that format
    /// has to be observable and has to follow `updateSourceFormat`.
    func testSourceFormatIsReadableAndFollowsUpdates() throws {
        let a = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let b = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url, sourceFormat: a)
        XCTAssertEqual(writer.sourceFormat.sampleRate, 44100)
        XCTAssertEqual(writer.sourceFormat.channelCount, 2)

        writer.updateSourceFormat(b)
        XCTAssertEqual(writer.sourceFormat.sampleRate, 16000)
        XCTAssertEqual(writer.sourceFormat.channelCount, 1)
        writer.finalize()
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

    /// The crash path: a hard kill (`_exit` on the second Ctrl+C, a crash,
    /// power loss) never gets to call `finalize()`. The header on disk must
    /// still describe every frame written, because the pipeline decides
    /// whether a track is empty — and whether to delete the WAV after
    /// compressing it — from exactly this number.
    func testHeaderStaysConsistentWithoutFinalize() throws {
        let source = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("w-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try WavWriter(url: url, sourceFormat: source)
        for _ in 0..<10 {
            try writer.write(makeSine(format: source, frames: 4410)) // 0.1 s each
        }
        // Deliberately NO finalize() — this is the whole point of the test.

        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBack.fileFormat.sampleRate, 48000)
        XCTAssertEqual(readBack.fileFormat.channelCount, 1)
        // Exact, not approximate: the size fields are rewritten after every
        // buffer, so the reader sees precisely what the writer counted.
        XCTAssertEqual(readBack.length, writer.framesWritten)
        XCTAssertGreaterThan(writer.framesWritten, 0)
        XCTAssertEqual(Double(readBack.length) / 48000, 1.0, accuracy: 0.02)
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

    // MARK: - stale header repair

    /// Reproduces the exact on-disk layout `AVAudioFile` leaves behind when
    /// it is killed before `close()`: `JUNK` + `fmt ` + `FLLR` padding
    /// chunks, payload page-aligned to offset 4096, RIFF size stuck at 4088
    /// and `data` size stuck at 0.
    func makeStaleAVAudioFileStyleWav(at url: URL, frames: Int) throws -> Int {
        var out = Data()
        func tag(_ text: String) { out.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }

        tag("RIFF"); u32(4088); tag("WAVE")             // stale: header-only size
        tag("JUNK"); u32(28); out.append(Data(count: 28))
        tag("fmt "); u32(16)
        u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16)
        tag("FLLR"); u32(4008); out.append(Data(count: 4008))
        tag("data"); u32(0)                             // stale: claims no audio
        XCTAssertEqual(out.count, 4096, "payload should be page-aligned like AVAudioFile's")

        for i in 0..<frames {
            let sample = Int16(sin(Double(i) * 0.05) * 8000)
            withUnsafeBytes(of: sample.littleEndian) { out.append(contentsOf: $0) }
        }
        try out.write(to: url)
        return out.count
    }

    func testRepairsStaleDataChunkSizeInPaddedWav() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stale-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = 24_000                              // 0.5 s at 48 kHz
        let totalSize = try makeStaleAVAudioFileStyleWav(at: url, frames: frames)

        // Precondition — this is the data-loss trigger itself: the file opens
        // happily and reports zero frames, so the compressor would encode an
        // empty m4a and then delete the only copy of the meeting.
        let staleRead = try AVAudioFile(forReading: url)
        XCTAssertEqual(staleRead.length, 0, "stale header should read as empty before repair")

        let outcome = try WavHeaderRepair.repairIfStale(at: url)
        XCTAssertEqual(outcome, .repaired(dataBytes: UInt32(frames * 2)))

        // The payload must be intact and now fully described by the header.
        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBack.length, AVAudioFramePosition(frames))
        XCTAssertEqual(readBack.fileFormat.sampleRate, 48000)
        let sizeAfter = (try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        XCTAssertEqual(sizeAfter, totalSize, "repair must not move or truncate audio")
    }

    func testRepairLeavesHealthyWavUntouched() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ok-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let writer = try WavWriter(url: url, sourceFormat: fmt)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
        buf.frameLength = 4800
        try writer.write(buf)
        writer.finalize()

        let before = try Data(contentsOf: url)
        XCTAssertEqual(try WavHeaderRepair.repairIfStale(at: url), .consistent)
        XCTAssertEqual(try Data(contentsOf: url), before, "healthy file must be byte-identical")
    }

    func testRepairIgnoresNonWavFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("junk-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try String(repeating: "not audio at all ", count: 8)
            .write(to: url, atomically: true, encoding: .utf8)

        let before = try Data(contentsOf: url)
        XCTAssertEqual(try WavHeaderRepair.repairIfStale(at: url), .unrecognized)
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
}
