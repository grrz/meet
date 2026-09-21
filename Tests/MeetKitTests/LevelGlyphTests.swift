import XCTest
@testable import MeetKit

final class LevelGlyphTests: XCTestCase {
    func testSilence() {
        XCTAssertEqual(LevelGlyph.glyph(forPeak: 0), "_")
        XCTAssertEqual(LevelGlyph.glyph(forPeak: 0.004), "_")
    }

    func testQuiet() {
        XCTAssertEqual(LevelGlyph.glyph(forPeak: 0.005), "⣀")
        XCTAssertEqual(LevelGlyph.glyph(forPeak: 0.019), "⣀")
    }

    func testLow() {
        XCTAssertEqual(LevelGlyph.glyph(forPeak: 0.02), "⣤")
        XCTAssertEqual(LevelGlyph.glyph(forPeak: 0.079), "⣤")
    }

    func testMedium() {
        XCTAssertEqual(LevelGlyph.glyph(forPeak: 0.08), "⣶")
        XCTAssertEqual(LevelGlyph.glyph(forPeak: 0.299), "⣶")
    }

    func testLoud() {
        XCTAssertEqual(LevelGlyph.glyph(forPeak: 0.3), "⣿")
        XCTAssertEqual(LevelGlyph.glyph(forPeak: 1.0), "⣿")
    }
}
