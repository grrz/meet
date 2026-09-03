import XCTest
@testable import MeetKit

final class TranscriptTests: XCTestCase {
    let opts = TranscriptOptions()

    func testInterleavesSpeakersChronologically() {
        let md = Transcript.assemble(
            me: [Segment(text: "Yes, loud and clear.", start: 6, end: 8)],
            them: [Segment(text: "Hi Greg, can you hear me?", start: 3, end: 5)],
            title: "Call 2026-09-03 14:20", durationSeconds: 3120, options: opts)
        XCTAssertEqual(md, """
        # Call 2026-09-03 14:20 (52 min)

        **[00:00:03] Them:** Hi Greg, can you hear me?
        **[00:00:06] Me:** Yes, loud and clear.

        """)
    }

    func testMergesSameSpeakerWithinGap() {
        let md = Transcript.assemble(
            me: [Segment(text: "So,", start: 10, end: 11),
                 Segment(text: "let's start.", start: 12, end: 13),
                 Segment(text: "Next topic.", start: 20, end: 21)],
            them: [],
            title: "T", durationSeconds: 30, options: opts)
        XCTAssertTrue(md.contains("**[00:00:10] Me:** So, let's start."))
        XCTAssertTrue(md.contains("**[00:00:20] Me:** Next topic."))
    }

    func testEmptyTracksProducePlaceholderLine() {
        let md = Transcript.assemble(me: [], them: [], title: "T",
                                     durationSeconds: 5, options: opts)
        XCTAssertTrue(md.contains("(5 sec)"))
        XCTAssertTrue(md.contains("_(no speech recognized)_"))
    }

    func testHourLongTimecodes() {
        let md = Transcript.assemble(
            me: [Segment(text: "still here", start: 3725, end: 3726)],
            them: [], title: "T", durationSeconds: 3800, options: opts)
        XCTAssertTrue(md.contains("**[01:02:05] Me:**"))
    }
}
