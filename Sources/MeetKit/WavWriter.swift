import AVFoundation
import Darwin
import Foundation

/// Errors thrown by `WavWriter`.
public enum WavWriterError: Error, CustomStringConvertible, LocalizedError {
    /// `AVAudioConverter(from:to:)` returned nil for the given formats
    /// (e.g. an unsupported channel layout or sample rate combination).
    case converterCreationFailed(source: AVAudioFormat, target: AVAudioFormat)
    /// `write(_:)` was called while no converter is available — this can
    /// only happen after `updateSourceFormat` was given a format it could
    /// not build a converter for.
    case noConverter
    /// The output file could not be created (permissions, missing parent
    /// directory, full disk).
    case fileCreationFailed(url: URL, code: Int32)
    /// A `write`/`pwrite` against the output file failed.
    case writeFailed(code: Int32)

    public var description: String {
        switch self {
        case .converterCreationFailed(let source, let target):
            return "WavWriter: could not create AVAudioConverter from \(source) to \(target)"
        case .noConverter:
            return "WavWriter: no audio converter is available (a previous updateSourceFormat call failed)"
        case .fileCreationFailed(let url, let code):
            return "WavWriter: could not create \(url.path): \(String(cString: strerror(code)))"
        case .writeFailed(let code):
            return "WavWriter: write failed: \(String(cString: strerror(code)))"
        }
    }

    public var errorDescription: String? { description }
}

/// Streams AVAudioPCMBuffers of any source format into a 48 kHz mono 16-bit WAV.
/// Not thread-safe by design: each recorder owns one writer and calls it from
/// a single audio callback thread. finalize() may be called from another thread
/// only after the callback source is stopped.
///
/// The file is written directly rather than through `AVAudioFile`, because
/// `AVAudioFile` defers its RIFF/data chunk size updates until `close()`. A
/// hard kill (the second Ctrl+C's `_exit`, a crash, power loss) therefore left
/// a WAV whose header claimed zero frames even though every audio byte was on
/// disk — and the pipeline then compressed that "empty" track into a stub m4a
/// and deleted the only copy of the meeting. Here the two size fields are
/// rewritten after *every* buffer, so the header on disk is always consistent
/// with the bytes on disk and a kill at any instant costs at most the audio
/// still buffered inside the converter.
public final class WavWriter {
    public static let targetSampleRate: Double = 48_000

    /// Canonical 44-byte PCM WAV header: RIFF/WAVE + 16-byte `fmt ` + `data`.
    private static let headerSize: Int = 44
    /// Offsets of the two length fields patched on every write.
    private static let riffSizeOffset: off_t = 4
    private static let dataSizeOffset: off_t = 40

    private let fd: Int32
    private let url: URL
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat
    private var closed = false
    /// Bytes of PCM payload written so far — the `data` chunk's size.
    private var dataBytes: UInt32 = 0
    public private(set) var framesWritten: AVAudioFramePosition = 0

    public var durationSeconds: Double {
        Double(framesWritten) / Self.targetSampleRate
    }

    public init(url: URL, sourceFormat: AVAudioFormat) throws {
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: Self.targetSampleRate,
                                          channels: 1, interleaved: true)!
        // Checked before the file is created, so a format we cannot convert
        // leaves nothing behind on disk.
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw WavWriterError.converterCreationFailed(source: sourceFormat, target: targetFormat)
        }

        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw WavWriterError.fileCreationFailed(url: url, code: errno)
        }
        self.fd = fd
        self.url = url
        self.targetFormat = targetFormat
        self.sourceFormat = sourceFormat
        self.converter = converter

        do {
            try writeInitialHeader()
        } catch {
            Darwin.close(fd)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    deinit {
        // Safety net for a writer dropped without finalize(): the header on
        // disk is already consistent, so this only reclaims the descriptor.
        if !closed { Darwin.close(fd) }
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

        try append(out)
    }

    public func finalize() {
        guard !closed else { return }
        if let converter {
            drainTail(of: converter, context: "finalize")
        }
        closed = true
        // The size fields are already current after every append; this is a
        // belt-and-braces refresh in case the last append failed midway.
        do {
            try updateSizeFields()
        } catch {
            fputs("WavWriter: failed to refresh WAV header during finalize: \(error)\n", stderr)
        }
        Darwin.close(fd)
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
                    try append(out)
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

    // MARK: - raw file writing

    /// Appends `buffer`'s int16 samples and republishes the header's size
    /// fields, keeping the file self-consistent at every instant.
    private func append(_ buffer: AVAudioPCMBuffer) throws {
        guard let channelData = buffer.int16ChannelData, buffer.frameLength > 0 else { return }
        // Mono: one channel, so interleaved and deinterleaved layouts coincide.
        let byteCount = Int(buffer.frameLength) * MemoryLayout<Int16>.size
        try writeAll(UnsafeRawPointer(channelData[0]), count: byteCount)
        dataBytes &+= UInt32(byteCount)
        framesWritten += AVAudioFramePosition(buffer.frameLength)
        try updateSizeFields()
    }

    private func writeInitialHeader() throws {
        var header = Data()
        header.reserveCapacity(Self.headerSize)
        func tag(_ text: String) { header.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { header.append(contentsOf: $0) }
        }

        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign = channels * bitsPerSample / 8
        let sampleRate = UInt32(Self.targetSampleRate)

        tag("RIFF")
        u32(UInt32(Self.headerSize - 8))            // no payload yet
        tag("WAVE")
        tag("fmt ")
        u32(16)                                     // PCM fmt chunk size
        u16(1)                                      // WAVE_FORMAT_PCM
        u16(channels)
        u32(sampleRate)
        u32(sampleRate * UInt32(blockAlign))        // byte rate
        u16(blockAlign)
        u16(bitsPerSample)
        tag("data")
        u32(0)                                      // no payload yet

        try header.withUnsafeBytes { try writeAll($0.baseAddress!, count: $0.count) }
    }

    private func updateSizeFields() throws {
        try pwriteU32(UInt32(Self.headerSize - 8) &+ dataBytes, at: Self.riffSizeOffset)
        try pwriteU32(dataBytes, at: Self.dataSizeOffset)
    }

    /// Sequential append at the descriptor's current offset.
    private func writeAll(_ pointer: UnsafeRawPointer, count: Int) throws {
        var base = pointer
        var remaining = count
        while remaining > 0 {
            let n = Darwin.write(fd, base, remaining)
            if n < 0 {
                if errno == EINTR { continue }
                throw WavWriterError.writeFailed(code: errno)
            }
            if n == 0 { throw WavWriterError.writeFailed(code: EIO) }
            base = base.advanced(by: n)
            remaining -= n
        }
    }

    /// Positioned write: patches a header field without disturbing the
    /// append offset, so no seek dance is needed around every buffer.
    private func pwriteU32(_ value: UInt32, at offset: off_t) throws {
        var littleEndian = value.littleEndian
        try withUnsafeBytes(of: &littleEndian) { raw in
            var base = raw.baseAddress!
            var remaining = raw.count
            var position = offset
            while remaining > 0 {
                let n = pwrite(fd, base, remaining, position)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WavWriterError.writeFailed(code: errno)
                }
                if n == 0 { throw WavWriterError.writeFailed(code: EIO) }
                base = base.advanced(by: n)
                remaining -= n
                position += off_t(n)
            }
        }
    }
}

/// Repairs WAV files whose RIFF/`data` chunk sizes were never finalized.
///
/// Lives next to `WavWriter` because it owns the on-disk format. It exists for
/// recordings made *before* `WavWriter` started keeping the header consistent:
/// those were written through `AVAudioFile`, which only stamps the real sizes
/// in `close()`, so a hard kill left `data size = 0` with megabytes of real
/// audio behind it. New recordings never need this, but it is cheap insurance
/// on every pipeline run.
///
/// Note the chunk list is *walked* rather than assumed: `AVAudioFile` writes
/// `JUNK` and `FLLR` padding chunks and page-aligns the payload, so on real
/// pre-fix files the `data` chunk starts at offset 4096, not 44. Blindly
/// patching offset 40 would corrupt exactly the files this rescues.
public enum WavHeaderRepair {
    public enum Outcome: Equatable {
        /// Not a RIFF/WAVE file, or too damaged to reason about — left alone.
        case unrecognized
        /// The header already describes the bytes on disk.
        case consistent
        /// Sizes were patched; `dataBytes` is the payload length now declared.
        case repaired(dataBytes: UInt32)
    }

    /// Inspects `url` and, if its declared sizes disagree with the bytes on
    /// disk, patches the RIFF and `data` size fields from the real file
    /// length. Never truncates, moves, or rewrites audio payload.
    @discardableResult
    public static func repairIfStale(at url: URL) throws -> Outcome {
        let fd = open(url.path, O_RDWR)
        guard fd >= 0 else { throw WavWriterError.fileCreationFailed(url: url, code: errno) }
        defer { Darwin.close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0 else { throw WavWriterError.writeFailed(code: errno) }
        let fileSize = Int(info.st_size)
        guard fileSize >= 44 else { return .unrecognized }

        // Enough to clear AVAudioFile's JUNK + FLLR padding (payload at 4096).
        var prefix = [UInt8](repeating: 0, count: min(fileSize, 65_536))
        let read = prefix.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard read > 0 else { throw WavWriterError.writeFailed(code: errno) }
        prefix.removeLast(prefix.count - read)

        func tag(_ offset: Int) -> String? {
            guard offset + 4 <= prefix.count else { return nil }
            return String(decoding: prefix[offset..<offset + 4], as: UTF8.self)
        }
        func u32(_ offset: Int) -> UInt32? {
            guard offset + 4 <= prefix.count else { return nil }
            return prefix[offset..<offset + 4].withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            }
        }
        func u16(_ offset: Int) -> UInt16? {
            guard offset + 2 <= prefix.count else { return nil }
            return prefix[offset..<offset + 2].withUnsafeBytes {
                $0.loadUnaligned(as: UInt16.self).littleEndian
            }
        }

        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return .unrecognized }

        // Walk the chunk list for `data`, noting `fmt `'s block alignment on
        // the way past so a payload cut mid-frame can be rounded down.
        var blockAlign: Int?
        var offset = 12
        var dataSizeFieldOffset: Int?
        var dataStart: Int?
        var declaredDataSize: UInt32?
        while offset + 8 <= prefix.count {
            guard let id = tag(offset), let size = u32(offset + 4) else { break }
            let payload = offset + 8
            if id == "data" {
                dataSizeFieldOffset = offset + 4
                dataStart = payload
                declaredDataSize = size
                break
            }
            if id == "fmt ", let align = u16(payload + 12), align > 0 {
                blockAlign = Int(align)
            }
            // Chunks are word-aligned: an odd size carries a pad byte.
            offset = payload + Int(size) + (Int(size) % 2)
        }

        guard let dataSizeFieldOffset, let dataStart, let declaredDataSize else {
            return .unrecognized
        }

        var actualDataBytes = fileSize - dataStart
        guard actualDataBytes > 0 else { return .consistent }
        if let blockAlign { actualDataBytes -= actualDataBytes % blockAlign }
        guard actualDataBytes > 0 else { return .consistent }

        // Repair only when the header claims nothing, or claims more than the
        // file holds. A declared size *smaller* than the remaining bytes can
        // legitimately mean trailing metadata chunks after the payload, and
        // swallowing those into the audio would be the wrong kind of fix.
        let stale = declaredDataSize == 0 || Int(declaredDataSize) > actualDataBytes
        guard stale else { return .consistent }

        let newDataSize = UInt32(actualDataBytes)
        let newRiffSize = UInt32(dataStart + actualDataBytes - 8)
        try pwriteU32(fd, newDataSize, at: off_t(dataSizeFieldOffset))
        try pwriteU32(fd, newRiffSize, at: 4)
        return .repaired(dataBytes: newDataSize)
    }

    private static func pwriteU32(_ fd: Int32, _ value: UInt32, at offset: off_t) throws {
        var littleEndian = value.littleEndian
        try withUnsafeBytes(of: &littleEndian) { raw in
            var base = raw.baseAddress!
            var remaining = raw.count
            var position = offset
            while remaining > 0 {
                let n = pwrite(fd, base, remaining, position)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw WavWriterError.writeFailed(code: errno)
                }
                if n == 0 { throw WavWriterError.writeFailed(code: EIO) }
                base = base.advanced(by: n)
                remaining -= n
                position += off_t(n)
            }
        }
    }
}
