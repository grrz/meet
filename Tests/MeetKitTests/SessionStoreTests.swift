import XCTest
@testable import MeetKit

final class SessionStoreTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meet-tests-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testCreateSessionMakesNamedFolder() throws {
        let store = SessionStore(rootDir: root)
        let date = ISO8601DateFormatter().date(from: "2026-09-03T14:20:00+03:00")!
        let session = try store.createSession(at: date)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.directory.path))
        XCTAssertTrue(session.directory.lastPathComponent.hasPrefix("2026-09-03-"))
        XCTAssertEqual(session.micWAV.lastPathComponent, "mic.wav")
    }

    func testCollisionAppendsSuffix() throws {
        let store = SessionStore(rootDir: root)
        let date = Date()
        let a = try store.createSession(at: date)
        let b = try store.createSession(at: date)
        let c = try store.createSession(at: date)
        XCTAssertNotEqual(a.directory, b.directory)
        XCTAssertNotEqual(b.directory, c.directory)
        XCTAssertTrue(b.directory.lastPathComponent.hasSuffix("-2"))
        XCTAssertTrue(c.directory.lastPathComponent.hasSuffix("-3"))
    }

    func testMetaRoundTripAndListing() throws {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())
        var meta = SessionMeta(startedAt: Date())
        meta.stage = .recorded
        meta.pauseIntervals = [PauseInterval(start: Date(), end: Date())]
        try session.saveMeta(meta)
        let loaded = try session.loadMeta()
        XCTAssertEqual(loaded.stage, .recorded)
        XCTAssertEqual(loaded.pauseIntervals.count, 1)

        let all = try store.allSessions()
        XCTAssertEqual(all.map(\.directory), [session.directory])
    }

    func testPerTrackStartTimestampsRoundTrip() throws {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())
        var meta = SessionMeta(startedAt: Date())
        // Whole seconds: the store encodes dates as plain ISO8601, which
        // carries no fractional part, so meta.json timestamps are
        // second-resolution — the same for these as for startedAt/endedAt.
        let systemStart = Date(timeIntervalSince1970: 1_772_000_000)
        let micStart = systemStart.addingTimeInterval(2)
        meta.systemStartedAt = systemStart
        meta.micStartedAt = micStart
        try session.saveMeta(meta)

        let loaded = try session.loadMeta()
        XCTAssertEqual(loaded.systemStartedAt?.timeIntervalSince1970 ?? 0,
                       systemStart.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(loaded.micStartedAt?.timeIntervalSince1970 ?? 0,
                       micStart.timeIntervalSince1970, accuracy: 0.001)
    }

    /// The new per-track timestamps are optional precisely so recordings made
    /// before they existed keep loading. A meta.json without them must decode,
    /// not throw.
    func testMetaWithoutPerTrackTimestampsStillDecodes() throws {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())
        try """
        {
          "startedAt" : "2026-09-03T14:20:00Z",
          "endedAt" : "2026-09-03T14:52:00Z",
          "stage" : "completed",
          "pauseIntervals" : [],
          "audioDurationSeconds" : 1920,
          "title" : "Legacy Call"
        }
        """.write(to: session.metaJSON, atomically: true, encoding: .utf8)

        let loaded = try session.loadMeta()
        XCTAssertEqual(loaded.stage, .completed)
        XCTAssertEqual(loaded.title, "Legacy Call")
        XCTAssertNil(loaded.micStartedAt)
        XCTAssertNil(loaded.systemStartedAt)
    }

    func testPerTrackDurationsRoundTrip() throws {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())
        var meta = SessionMeta(startedAt: Date())
        meta.micDurationSeconds = 1234.5
        meta.systemDurationSeconds = 1230.0
        try session.saveMeta(meta)

        let loaded = try session.loadMeta()
        XCTAssertEqual(loaded.micDurationSeconds ?? 0, 1234.5, accuracy: 0.001)
        XCTAssertEqual(loaded.systemDurationSeconds ?? 0, 1230.0, accuracy: 0.001)
    }

    /// Per-track durations are optional precisely so recordings made before
    /// they existed keep loading. A meta.json without them must decode, not
    /// throw.
    func testMetaWithoutPerTrackDurationsStillDecodes() throws {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())
        try """
        {
          "startedAt" : "2026-09-03T14:20:00Z",
          "endedAt" : "2026-09-03T14:52:00Z",
          "stage" : "completed",
          "pauseIntervals" : [],
          "audioDurationSeconds" : 1920,
          "title" : "Legacy Call"
        }
        """.write(to: session.metaJSON, atomically: true, encoding: .utf8)

        let loaded = try session.loadMeta()
        XCTAssertEqual(loaded.stage, .completed)
        XCTAssertNil(loaded.micDurationSeconds)
        XCTAssertNil(loaded.systemDurationSeconds)
    }

    func testStageOrdering() {
        XCTAssertTrue(Stage.recorded < Stage.transcribed)
        XCTAssertTrue(Stage.merged < Stage.completed)
    }

    func testDisplayTitleWithCustomTitle() throws {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())
        var meta = SessionMeta(startedAt: Date())
        meta.title = "Engineering Sync"
        let displayTitle = session.displayTitle(meta: meta)
        XCTAssertEqual(displayTitle, "Engineering Sync")
    }

    func testDisplayTitleWithoutTitleUsesStartedAt() throws {
        let store = SessionStore(rootDir: root)
        let session = try store.createSession(at: Date())
        // Construct date using DateComponents to avoid timezone parsing issues
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 3
        components.hour = 14
        components.minute = 20
        let calendar = Calendar(identifier: .gregorian)
        let knownDate = calendar.date(from: components)!
        let meta = SessionMeta(startedAt: knownDate)
        let displayTitle = session.displayTitle(meta: meta)
        XCTAssertEqual(displayTitle, "Call 2026-09-03 14:20")
    }
}
