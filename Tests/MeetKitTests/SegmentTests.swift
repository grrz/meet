import XCTest
@testable import MeetKit

final class SegmentTests: XCTestCase {
    func testSegmentRoundTrip() throws {
        let s = Segment(text: "hi", start: 0.5, end: 1.25)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Segment.self, from: data)
        XCTAssertEqual(s, back)
    }

    func testParsesParakeetShape() throws {
        let json = """
        {"text": "Hello world.",
         "sentences": [
           {"text": "Hello", "start": 0.1, "end": 0.8, "duration": 0.7, "confidence": 0.98, "tokens": []},
           {"text": "world.", "start": 0.9, "end": 1.4, "duration": 0.5, "confidence": 0.97, "tokens": []}
         ]}
        """.data(using: .utf8)!
        let segs = try SegmentParser.parse(json)
        XCTAssertEqual(segs, [
            Segment(text: "Hello", start: 0.1, end: 0.8),
            Segment(text: "world.", start: 0.9, end: 1.4),
        ])
    }

    func testParsesBareArrayAndSegmentsKeySortedByStart() throws {
        let bare = """
        [{"text": "b", "start": 2.0, "end": 3.0}, {"text": "a", "start": 0.0, "end": 1.0}]
        """.data(using: .utf8)!
        XCTAssertEqual(try SegmentParser.parse(bare).map(\.text), ["a", "b"])

        let keyed = """
        {"segments": [{"text": "x", "start": 0, "end": 1}]}
        """.data(using: .utf8)!
        XCTAssertEqual(try SegmentParser.parse(keyed).count, 1)
    }

    func testRejectsUnknownShape() {
        let bad = "{\"foo\": 1}".data(using: .utf8)!
        XCTAssertThrowsError(try SegmentParser.parse(bad))
    }

    func testParsesEmptyArray() throws {
        let json = "[]".data(using: .utf8)!
        let segs = try SegmentParser.parse(json)
        XCTAssertEqual(segs, [])
    }

    func testRejectsWrongFieldTypes() {
        let badType = """
        [{"text": "hello", "start": "0.1", "end": 1.0}]
        """.data(using: .utf8)!
        XCTAssertThrowsError(try SegmentParser.parse(badType))
    }

    func testRejectsMissingRequiredField() {
        let missing = """
        [{"text": "hello", "start": 0.1}]
        """.data(using: .utf8)!
        XCTAssertThrowsError(try SegmentParser.parse(missing))
    }

    func testRejectsObjectInsteadOfArray() {
        let obj = """
        {"segments": {"a": 1}}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try SegmentParser.parse(obj))
    }
}
