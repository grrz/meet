import XCTest
@testable import MeetKit

final class ConfigTests: XCTestCase {
    func testMissingFileGivesDefaults() throws {
        let cfg = try Config.load(path: URL(fileURLWithPath: "/nonexistent/config.toml"))
        XCTAssertEqual(cfg, Config.default)
        XCTAssertTrue(cfg.sttCommand.contains("parakeet-mlx"))
        XCTAssertEqual(cfg.transcript.speakerMe, "Me")
        XCTAssertFalse(cfg.debug)
        XCTAssertTrue(cfg.saveAudio)
    }

    func testDebugAndSaveAudioOverride() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try """
        debug = true
        save_audio = false
        """.write(to: path, atomically: true, encoding: .utf8)

        let cfg = try Config.load(path: path)
        XCTAssertTrue(cfg.debug)
        XCTAssertFalse(cfg.saveAudio)
    }

    func testPartialFileOverridesOnlyGivenKeys() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try """
        recordings_dir = "/tmp/rec"

        [transcript]
        speaker_me = "Greg"
        """.write(to: path, atomically: true, encoding: .utf8)

        let cfg = try Config.load(path: path)
        XCTAssertEqual(cfg.recordingsDir.path, "/tmp/rec")
        XCTAssertEqual(cfg.transcript.speakerMe, "Greg")
        XCTAssertEqual(cfg.transcript.speakerThem, "Them")       // default kept
        XCTAssertEqual(cfg.sttCommand, Config.default.sttCommand) // default kept
        XCTAssertFalse(cfg.debug)                                 // default kept
        XCTAssertTrue(cfg.saveAudio)                              // default kept
    }

    func testTildeExpansion() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try "recordings_dir = \"~/SomeDir\"".write(to: path, atomically: true, encoding: .utf8)
        let cfg = try Config.load(path: path)
        XCTAssertFalse(cfg.recordingsDir.path.contains("~"))
    }

    func testMalformedTOMLThrows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try "recordings_dir = [unclosed".write(to: path, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try Config.load(path: path))
    }

    func testIntegerMergeGapSeconds() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config.toml")
        try """
        [transcript]
        merge_gap_seconds = 2
        """.write(to: path, atomically: true, encoding: .utf8)

        let cfg = try Config.load(path: path)
        XCTAssertEqual(cfg.transcript.mergeGapSeconds, 2.0)
    }
}
