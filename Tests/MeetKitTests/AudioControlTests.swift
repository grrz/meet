import XCTest
@testable import MeetKit

/// The audio-control queue is the one piece of the concurrency rework that can
/// be exercised without a real audio device: its re-entrancy contract is what
/// keeps `stop()` from deadlocking when it is called from an `onEvent`
/// consumer (those callbacks run on this very queue), and its serialization is
/// what keeps the two recorders' rebuilds from overlapping inside CoreAudio.
final class AudioControlTests: XCTestCase {
    /// Boxed so several queues can append to it under `AudioControl`'s own
    /// serialization rather than needing a lock of its own.
    private final class Box {
        var values: [Int] = []
    }

    func testSyncRunsWorkOnTheQueueAndReturnsItsValue() {
        var wasOnQueue = false
        let result: Int = AudioControl.sync {
            wasOnQueue = AudioControl.isCurrent
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertTrue(wasOnQueue)
    }

    func testIsCurrentIsFalseOffTheQueue() {
        XCTAssertFalse(AudioControl.isCurrent)
    }

    func testSyncRethrows() {
        struct Boom: Error {}
        XCTAssertThrowsError(try AudioControl.sync { throw Boom() })
    }

    /// A plain `queue.sync` from a block already running on that queue
    /// deadlocks; `AudioControl.sync` must run the work inline instead. Driven
    /// from a background queue with an expectation so a regression fails the
    /// test rather than hanging the whole suite.
    func testSyncIsReentrantFromTheQueueItself() {
        let finished = expectation(description: "nested sync returned")
        var inner = 0
        DispatchQueue.global().async {
            AudioControl.sync {
                inner = AudioControl.sync { 7 }
            }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(inner, 7)
    }

    func testAsyncWorkRunsSeriallyInOrder() {
        let box = Box()
        for value in 0..<50 {
            AudioControl.async { box.values.append(value) }
        }
        // Drains the queue: this only runs once every block above has.
        AudioControl.sync {}
        XCTAssertEqual(box.values, Array(0..<50))
    }

    /// `async` never runs inline, even when called from the queue — that is
    /// what makes it safe for a recorder to deliver `onEvent` in the middle of
    /// a rebuild without a consumer's `stop()` re-entering that rebuild.
    func testAsyncNeverRunsInline() {
        let box = Box()
        AudioControl.sync {
            AudioControl.async { box.values.append(1) }
            XCTAssertTrue(box.values.isEmpty)
        }
        AudioControl.sync {}
        XCTAssertEqual(box.values, [1])
    }
}
