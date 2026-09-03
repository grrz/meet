import XCTest
@testable import MeetKit

final class SegmentTests: XCTestCase {
    func testSegmentRoundTrip() throws {
        let s = Segment(text: "hi", start: 0.5, end: 1.25)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Segment.self, from: data)
        XCTAssertEqual(s, back)
    }
}
