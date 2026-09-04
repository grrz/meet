import XCTest
@testable import MeetKit

final class StallDetectorTests: XCTestCase {
    func testFreshDetectorIsNotStalled() {
        var detector = StallDetector(thresholdSeconds: 5)
        let now = Date()
        XCTAssertFalse(detector.update(duration: 0, isPaused: false, now: now))
    }

    func testStallsAfterThresholdOfFrozenDuration() {
        var detector = StallDetector(thresholdSeconds: 5)
        let t0 = Date()
        XCTAssertFalse(detector.update(duration: 12.0, isPaused: false, now: t0))
        // Same duration, just under the threshold: not stalled yet.
        XCTAssertFalse(detector.update(duration: 12.0, isPaused: false, now: t0.addingTimeInterval(4.9)))
        // Same duration, at/over the threshold: stalled.
        XCTAssertTrue(detector.update(duration: 12.0, isPaused: false, now: t0.addingTimeInterval(5.0)))
        // Stays stalled while duration keeps not moving.
        XCTAssertTrue(detector.update(duration: 12.0, isPaused: false, now: t0.addingTimeInterval(9.0)))
    }

    func testPausePreventsStall() {
        var detector = StallDetector(thresholdSeconds: 5)
        let t0 = Date()
        XCTAssertFalse(detector.update(duration: 12.0, isPaused: false, now: t0))
        // Paused with a frozen duration for far longer than the threshold:
        // pause is a legitimate stall, never reported.
        XCTAssertFalse(detector.update(duration: 12.0, isPaused: true, now: t0.addingTimeInterval(1)))
        XCTAssertFalse(detector.update(duration: 12.0, isPaused: true, now: t0.addingTimeInterval(30)))
        XCTAssertFalse(detector.update(duration: 12.0, isPaused: true, now: t0.addingTimeInterval(60)))
    }

    func testResumeAfterPauseGetsAFreshWindow() {
        var detector = StallDetector(thresholdSeconds: 5)
        let t0 = Date()
        _ = detector.update(duration: 12.0, isPaused: false, now: t0)
        // Every paused tick keeps resetting the clock (mirrors InteractiveUI
        // ticking ~1/s straight through a pause), so the window that matters
        // after resume starts at the *last* paused tick, here t0+60.
        _ = detector.update(duration: 12.0, isPaused: true, now: t0.addingTimeInterval(60))
        // Resumed right away; duration hasn't moved yet (writer hasn't
        // produced a new buffer this tick), but the clock restarted at the
        // last paused tick, not at t0 — so this must not immediately read
        // as stalled.
        XCTAssertFalse(detector.update(duration: 12.0, isPaused: false, now: t0.addingTimeInterval(61)))
        XCTAssertFalse(detector.update(duration: 12.0, isPaused: false, now: t0.addingTimeInterval(64.9)))
        XCTAssertTrue(detector.update(duration: 12.0, isPaused: false, now: t0.addingTimeInterval(65.0)))
    }

    func testRecoveryClearsStall() {
        var detector = StallDetector(thresholdSeconds: 5)
        let t0 = Date()
        _ = detector.update(duration: 12.0, isPaused: false, now: t0)
        XCTAssertTrue(detector.update(duration: 12.0, isPaused: false, now: t0.addingTimeInterval(5)))
        // Duration moves again: recovered immediately.
        XCTAssertFalse(detector.update(duration: 13.5, isPaused: false, now: t0.addingTimeInterval(5.1)))
    }

    func testDefaultThresholdIsFiveSeconds() {
        var detector = StallDetector()
        let t0 = Date()
        _ = detector.update(duration: 1.0, isPaused: false, now: t0)
        XCTAssertFalse(detector.update(duration: 1.0, isPaused: false, now: t0.addingTimeInterval(4.9)))
        XCTAssertTrue(detector.update(duration: 1.0, isPaused: false, now: t0.addingTimeInterval(5.0)))
    }
}
