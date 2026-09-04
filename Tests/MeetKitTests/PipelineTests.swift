import XCTest
import AVFoundation
@testable import MeetKit

final class PipelineTests: XCTestCase {
    var root: URL!
    var fakeEngine: URL!
    var config: Config!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pipe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // Fake engine echoes one segment whose text is the audio stem.
        fakeEngine = root.appendingPathComponent("fake-engine.sh")
        try """
        #!/bin/sh
        stem=$(basename "$1")
        stem="${stem%.*}"
        printf '{"segments":[{"text":"%s speech","start":1.0,"end":2.0}]}' "$stem" > "$2/$stem.json"
        """.write(to: fakeEngine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: fakeEngine.path)

        config = Config.default
        config.recordingsDir = root
        config.sttCommand = "\(shellQuote(fakeEngine.path)) {audio} {outdir}"
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func makeRecordedSession(withSystemTrack: Bool = true) throws -> Session {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        for url in withSystemTrack ? [session.micWAV, session.systemWAV] : [session.micWAV] {
            let w = try WavWriter(url: url, sourceFormat: fmt)
            let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4800)!
            buf.frameLength = 4800
            try w.write(buf)
            w.finalize()
        }
        var meta = SessionMeta(startedAt: Date())
        meta.stage = .recorded
        meta.endedAt = Date()
        meta.audioDurationSeconds = 0.1
        try session.saveMeta(meta)
        return session
    }

    func testFullPipelineRunsAllStages() throws {
        let session = try makeRecordedSession()
        try Pipeline(config: config).process(session: session)

        let meta = try session.loadMeta()
        XCTAssertEqual(meta.stage, .completed)
        XCTAssertEqual(meta.engineCommand, config.sttCommand)

        let transcript = try String(contentsOf: session.transcriptMD, encoding: .utf8)
        XCTAssertTrue(transcript.contains("00:00:01 Me: mic speech"))
        XCTAssertTrue(transcript.contains("Them: system speech"))

        // Default config: debug = false, save_audio = true — audio is kept as
        // m4a, but the intermediate STT/log files are cleaned up.
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: session.micWAV.path))
        XCTAssertTrue(fm.fileExists(atPath: session.micM4A.path))
        XCTAssertTrue(fm.fileExists(atPath: session.systemM4A.path))
        XCTAssertFalse(fm.fileExists(atPath: session.micJSON.path))
        XCTAssertFalse(fm.fileExists(atPath: session.systemJSON.path))
        XCTAssertFalse(fm.fileExists(atPath: session.logFile.path))
        XCTAssertTrue(fm.fileExists(atPath: session.metaJSON.path))
    }

    /// debug = true keeps the pre-cleanup intermediate files regardless of
    /// save_audio, for inspecting a session's raw STT output and log.
    func testDebugKeepsIntermediateFiles() throws {
        var debugConfig = config!
        debugConfig.debug = true
        debugConfig.saveAudio = false // must be ignored while debug is true
        let session = try makeRecordedSession()
        try Pipeline(config: debugConfig).process(session: session)

        XCTAssertEqual(try session.loadMeta().stage, .completed)
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: session.micWAV.path))
        XCTAssertTrue(fm.fileExists(atPath: session.micM4A.path))
        XCTAssertTrue(fm.fileExists(atPath: session.systemM4A.path))
        XCTAssertTrue(fm.fileExists(atPath: session.micJSON.path))
        XCTAssertTrue(fm.fileExists(atPath: session.systemJSON.path))
        XCTAssertTrue(fm.fileExists(atPath: session.logFile.path))
        XCTAssertTrue(fm.fileExists(atPath: session.metaJSON.path))
    }

    /// debug = false, save_audio = false: no m4a is ever created, the WAVs
    /// are deleted directly, and the folder ends up with just the transcript
    /// and meta.json.
    func testSaveAudioFalseDeletesWavWithoutCompressing() throws {
        var cfg = config!
        cfg.saveAudio = false
        let session = try makeRecordedSession()
        try Pipeline(config: cfg).process(session: session)

        XCTAssertEqual(try session.loadMeta().stage, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.transcriptMD.path))

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: session.micWAV.path))
        XCTAssertFalse(fm.fileExists(atPath: session.systemWAV.path))
        XCTAssertFalse(fm.fileExists(atPath: session.micM4A.path))
        XCTAssertFalse(fm.fileExists(atPath: session.systemM4A.path))
        XCTAssertFalse(fm.fileExists(atPath: session.micJSON.path))
        XCTAssertFalse(fm.fileExists(atPath: session.systemJSON.path))
        XCTAssertFalse(fm.fileExists(atPath: session.logFile.path))
        XCTAssertTrue(fm.fileExists(atPath: session.metaJSON.path))
    }

    /// Cleanup removal is best-effort: a track that never recorded (no WAV
    /// ever written for it) must not make the final stage fail when its
    /// removal is attempted.
    func testCleanupIsBestEffortWhenFilesAlreadyMissing() throws {
        var cfg = config!
        cfg.saveAudio = false
        let session = try makeRecordedSession(withSystemTrack: false)
        try Pipeline(config: cfg).process(session: session)
        XCTAssertEqual(try session.loadMeta().stage, .completed)
    }

    /// A session recorded with save_audio = false has no audio left once
    /// completed. Forcing a re-transcribe must refuse clearly, and must not
    /// touch the stage or the existing transcript first.
    func testForceReprocessWithoutAudioThrows() throws {
        var cfg = config!
        cfg.saveAudio = false
        let session = try makeRecordedSession()
        let pipeline = Pipeline(config: cfg)
        try pipeline.process(session: session)
        XCTAssertEqual(try session.loadMeta().stage, .completed)
        let transcriptBefore = try String(contentsOf: session.transcriptMD, encoding: .utf8)

        XCTAssertThrowsError(try pipeline.process(session: session, force: true)) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("save_audio = false"), message)
        }

        // Refused before doing any work: stage and transcript are untouched.
        XCTAssertEqual(try session.loadMeta().stage, .completed)
        let transcriptAfter = try String(contentsOf: session.transcriptMD, encoding: .utf8)
        XCTAssertEqual(transcriptBefore, transcriptAfter)
    }

    func testMissingTrackYieldsEmptySegments() throws {
        // debug = true so the intermediate mic.json/pipeline.log this test
        // inspects survive the final cleanup stage.
        var debugConfig = config!
        debugConfig.debug = true
        let session = try makeRecordedSession(withSystemTrack: false)
        try Pipeline(config: debugConfig).process(session: session)
        let systemSegs = try SegmentParser.parse(Data(contentsOf: session.systemJSON))
        XCTAssertEqual(systemSegs, [])
        XCTAssertEqual(try session.loadMeta().stage, .completed)

        let log = try String(contentsOf: session.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("missing; writing empty segments"))
    }

    func testFailedEngineKeepsWavAndStage() throws {
        let session = try makeRecordedSession()

        // Engine that emits identifiable output before failing, so we can
        // assert the failure is actually captured in session.logFile.
        let explodingEngine = root.appendingPathComponent("exploding-engine.sh")
        try """
        #!/bin/sh
        echo "engine exploded" >&2
        exit 3
        """.write(to: explodingEngine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: explodingEngine.path)

        var broken = config!
        broken.sttCommand = "\(shellQuote(explodingEngine.path)) {audio} {outdir}"
        XCTAssertThrowsError(try Pipeline(config: broken).process(session: session))
        XCTAssertEqual(try session.loadMeta().stage, .recorded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.micWAV.path))

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.logFile.path))
        let log = try String(contentsOf: session.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("$ \(shellQuote(explodingEngine.path))"),
                      "log should contain the rendered command line")
        XCTAssertTrue(log.contains("engine exploded"),
                      "log should contain the engine's captured output")
    }

    func testResumeFromTranscribed() throws {
        let session = try makeRecordedSession()
        var broken = config!
        broken.sttCommand = "false {audio} {outdir}"
        try? Pipeline(config: broken).process(session: session)      // fails, stays recorded
        try Pipeline(config: config).process(session: session)       // catches up fully
        XCTAssertEqual(try session.loadMeta().stage, .completed)
    }

    func testForceRerunsCompletedSessionFromM4a() throws {
        let session = try makeRecordedSession()
        let pipeline = Pipeline(config: config)
        try pipeline.process(session: session)                       // completed, WAVs gone
        try pipeline.process(session: session, force: true)          // must transcribe m4a
        XCTAssertEqual(try session.loadMeta().stage, .completed)
        let transcript = try String(contentsOf: session.transcriptMD, encoding: .utf8)
        XCTAssertTrue(transcript.contains("mic speech"))
    }

    /// A --force rerun must persist its stage reset before doing any work, so
    /// a failure leaves the session at `recorded` — retryable with a plain
    /// `meet process` — rather than at `completed` with mixed artifacts.
    func testFailedForceRerunLeavesStageRetryable() throws {
        let session = try makeRecordedSession()
        let pipeline = Pipeline(config: config)
        try pipeline.process(session: session)
        XCTAssertEqual(try session.loadMeta().stage, .completed)

        var broken = config!
        broken.sttCommand = "false {audio} {outdir}"
        XCTAssertThrowsError(try Pipeline(config: broken).process(session: session, force: true))

        // Without the pre-work saveMeta this reads `completed`, and a plain
        // rerun would skip the session instead of picking it back up.
        XCTAssertEqual(try session.loadMeta().stage, .recorded)

        try pipeline.process(session: session)                       // plain retry catches up
        XCTAssertEqual(try session.loadMeta().stage, .completed)
    }

    /// A recording killed before its WAV header was finalized reports zero
    /// frames over real audio. The pipeline must repair the header rather than
    /// transcribe silence and then compress the track into an empty m4a.
    func testRepairsStaleWavHeaderBeforeTranscribing() throws {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())

        for url in [session.micWAV, session.systemWAV] {
            try writeStaleHeaderWav(at: url, frames: 24_000)         // 0.5 s each
            // Precondition: the track currently reads as empty.
            XCTAssertEqual(try AVAudioFile(forReading: url).length, 0)
        }
        var meta = SessionMeta(startedAt: Date())
        meta.stage = .recorded
        meta.endedAt = Date()
        try session.saveMeta(meta)

        // debug = true so pipeline.log, inspected below, survives cleanup.
        var debugConfig = config!
        debugConfig.debug = true
        try Pipeline(config: debugConfig).process(session: session)

        XCTAssertEqual(try session.loadMeta().stage, .completed)
        let transcript = try String(contentsOf: session.transcriptMD, encoding: .utf8)
        XCTAssertTrue(transcript.contains("mic speech"))
        XCTAssertTrue(transcript.contains("system speech"))

        let log = try String(contentsOf: session.logFile, encoding: .utf8)
        XCTAssertTrue(log.contains("repaired stale WAV header: mic.wav"), log)
        XCTAssertTrue(log.contains("repaired stale WAV header: system.wav"), log)

        // The rescued audio really was compressible: with a zero-frame header
        // the compressor would have refused and the run would have failed.
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: session.micM4A.path))
        XCTAssertTrue(fm.fileExists(atPath: session.systemM4A.path))
    }

    /// Canonical 44-byte header with both size fields zeroed, followed by real
    /// PCM payload — the shape a hard kill leaves behind.
    private func writeStaleHeaderWav(at url: URL, frames: Int) throws {
        var out = Data()
        func tag(_ text: String) { out.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        func u16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
        }
        tag("RIFF"); u32(36); tag("WAVE")            // stale: header-only size
        tag("fmt "); u32(16)
        u16(1); u16(1); u32(48000); u32(96000); u16(2); u16(16)
        tag("data"); u32(0)                          // stale: claims no audio
        for i in 0..<frames {
            let sample = Int16(sin(Double(i) * 0.05) * 8000)
            withUnsafeBytes(of: sample.littleEndian) { out.append(contentsOf: $0) }
        }
        try out.write(to: url)
    }
}
