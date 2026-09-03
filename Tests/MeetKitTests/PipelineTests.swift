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
        XCTAssertTrue(transcript.contains("**[00:00:01] Me:** mic speech"))
        XCTAssertTrue(transcript.contains("Them:** system speech"))

        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: session.micWAV.path))
        XCTAssertTrue(fm.fileExists(atPath: session.micM4A.path))
        XCTAssertTrue(fm.fileExists(atPath: session.systemM4A.path))
        XCTAssertTrue(fm.fileExists(atPath: session.micJSON.path))
    }

    func testMissingTrackYieldsEmptySegments() throws {
        let session = try makeRecordedSession(withSystemTrack: false)
        try Pipeline(config: config).process(session: session)
        let systemSegs = try SegmentParser.parse(Data(contentsOf: session.systemJSON))
        XCTAssertEqual(systemSegs, [])
        XCTAssertEqual(try session.loadMeta().stage, .completed)
    }

    func testFailedEngineKeepsWavAndStage() throws {
        let session = try makeRecordedSession()
        var broken = config!
        broken.sttCommand = "false {audio} {outdir}"
        XCTAssertThrowsError(try Pipeline(config: broken).process(session: session))
        XCTAssertEqual(try session.loadMeta().stage, .recorded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.micWAV.path))
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
}
