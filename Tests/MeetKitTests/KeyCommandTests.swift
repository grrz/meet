import XCTest
@testable import MeetKit

final class KeyCommandTests: XCTestCase {
    func testToggleRecordingKeys() {
        for key in ["z", "Z", "я", "Я"] {
            XCTAssertEqual(KeyCommand.parse(key), .toggleRecording, "key: \(key)")
        }
    }

    func testQuitKeys() {
        for key in ["q", "Q", "й", "Й", "\u{04}"] {
            XCTAssertEqual(KeyCommand.parse(key), .quit, "key: \(key)")
        }
    }

    func testSpaceKey() {
        XCTAssertEqual(KeyCommand.parse(" "), .space)
    }

    func testUnmappedKeysReturnNil() {
        for key in ["a", "1", "\n", "", "ф"] {
            XCTAssertNil(KeyCommand.parse(key), "key: \(key)")
        }
    }
}
