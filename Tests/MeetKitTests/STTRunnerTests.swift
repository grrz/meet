import XCTest
@testable import MeetKit

final class STTRunnerTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testShellQuoting() {
        XCTAssertEqual(shellQuote("/a b/c'd"), "'/a b/c'\\''d'")
    }

    func testRenderSubstitutesQuotedPaths() {
        let runner = STTRunner(commandTemplate: "engine {audio} --out {outdir}")
        let cmd = runner.render(audio: URL(fileURLWithPath: "/tmp/a b.wav"),
                                outdir: URL(fileURLWithPath: "/tmp/out"))
        XCTAssertEqual(cmd, "engine '/tmp/a b.wav' --out '/tmp/out'")
    }

    /// Fake engine: a shell script that writes a fixture JSON named after the audio stem.
    func testRunsFakeEngineAndParsesOutput() throws {
        let audio = dir.appendingPathComponent("mic.wav")
        try Data().write(to: audio)
        let engine = dir.appendingPathComponent("fake-engine.sh")
        try """
        #!/bin/sh
        # $1 = audio path, $2 = outdir
        stem=$(basename "$1" .wav)
        printf '{"sentences":[{"text":"hello","start":0.0,"end":1.0}]}' > "$2/$stem.json"
        echo "fake engine done"
        """.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: engine.path)

        let runner = STTRunner(commandTemplate: "\(shellQuote(engine.path)) {audio} {outdir}")
        let log = dir.appendingPathComponent("run.log")
        let segments = try runner.transcribe(audio: audio, outdir: dir, log: log)

        XCTAssertEqual(segments, [Segment(text: "hello", start: 0.0, end: 1.0)])
        let logText = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logText.contains("fake engine done"))
    }

    func testNonzeroExitThrows() throws {
        let audio = dir.appendingPathComponent("mic.wav")
        try Data().write(to: audio)
        let runner = STTRunner(commandTemplate: "false {audio} {outdir}")
        XCTAssertThrowsError(try runner.transcribe(
            audio: audio, outdir: dir, log: dir.appendingPathComponent("l.log"))) { error in
            guard case STTError.engineFailed = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    func testMissingOutputThrows() throws {
        let audio = dir.appendingPathComponent("mic.wav")
        try Data().write(to: audio)
        let runner = STTRunner(commandTemplate: "true {audio} {outdir}")
        XCTAssertThrowsError(try runner.transcribe(
            audio: audio, outdir: dir, log: dir.appendingPathComponent("l.log"))) { error in
            guard case STTError.outputMissing = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
    }

    /// Regression test for race condition: large stderr burst before nonzero exit.
    /// Verifies log contains the final line of output before process exits.
    func testLargeStderrBurstCapturedBeforeNonzeroExit() throws {
        let audio = dir.appendingPathComponent("mic.wav")
        try Data().write(to: audio)
        let engine = dir.appendingPathComponent("burst-engine.sh")
        // Emit multi-kilobyte burst to stderr then exit with code 1
        try """
        #!/bin/sh
        for i in $(seq 1 100); do
            echo "error line $i: $(printf '%100s' | tr ' ' 'x')" >&2
        done
        exit 1
        """.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: engine.path)

        let runner = STTRunner(commandTemplate: "\(shellQuote(engine.path)) {audio} {outdir}")
        let log = dir.appendingPathComponent("burst.log")

        XCTAssertThrowsError(try runner.transcribe(audio: audio, outdir: dir, log: log)) { error in
            guard case STTError.engineFailed = error else {
                return XCTFail("expected engineFailed, got \(error)")
            }
        }

        let logText = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logText.contains("error line 100"), "log should contain final stderr line")
    }

    /// Test for append-or-create semantics: two consecutive transcribe calls
    /// with the same log URL should preserve both commands' output.
    func testConsecutiveTranscribeCallsAppendToLog() throws {
        let mic = dir.appendingPathComponent("mic.wav")
        try Data().write(to: mic)
        let sys = dir.appendingPathComponent("system.wav")
        try Data().write(to: sys)

        let engine = dir.appendingPathComponent("dual-engine.sh")
        try """
        #!/bin/sh
        stem=$(basename "$1" .wav)
        printf '{"sentences":[{"text":"test","start":0.0,"end":1.0}]}' > "$2/$stem.json"
        echo "transcribed $stem"
        """.write(to: engine, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: engine.path)

        let runner = STTRunner(commandTemplate: "\(shellQuote(engine.path)) {audio} {outdir}")
        let log = dir.appendingPathComponent("dual.log")

        // First transcribe: mic
        _ = try runner.transcribe(audio: mic, outdir: dir, log: log)
        // Second transcribe: system (same log file)
        _ = try runner.transcribe(audio: sys, outdir: dir, log: log)

        let logText = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(logText.contains("transcribed mic"), "log should contain first command output")
        XCTAssertTrue(logText.contains("transcribed system"), "log should contain second command output")
        // Verify both commands appear in order
        let micIdx = logText.range(of: "transcribed mic")!.lowerBound
        let sysIdx = logText.range(of: "transcribed system")!.lowerBound
        XCTAssertTrue(micIdx < sysIdx, "mic output should appear before system output")
    }
}
