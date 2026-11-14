import XCTest
@testable import RunespeakCore

final class SenderMemoryTests: XCTestCase {
    func testThinGlyphSlipsSnapToTheKnownName() {
        var memory = SenderMemory()
        XCTAssertEqual(memory.resolve("Thrall"), "Thrall")
        XCTAssertEqual(memory.resolve("Thrall"), "Thrall")
        XCTAssertEqual(memory.resolve("Thral"), "Thrall")      // a letter eaten by the bracket
        XCTAssertEqual(memory.resolve("Thralll"), "Thrall")    // the bracket read as a letter
        XCTAssertEqual(memory.resolve("Thrali"), "Thrall")     // l read as i
        XCTAssertEqual(memory.resolve("thrall"), "Thrall")     // case only
        XCTAssertEqual(memory.resolve("Jaina"), "Jaina")
        XCTAssertEqual(memory.resolve("aina"), "Jaina")        // "[J" merged
        XCTAssertEqual(memory.resolve("Jainal"), "Jaina")
    }

    func testDifferentNamesAreLeftAlone() {
        var memory = SenderMemory()
        for _ in 0..<3 { _ = memory.resolve("Arthas") }
        XCTAssertEqual(memory.resolve("Arthass"), "Arthass")   // "s" is not a thin glyph
        XCTAssertEqual(memory.resolve("Arthus"), "Arthus")
        XCTAssertEqual(memory.resolve("Anduin"), "Anduin")
        XCTAssertEqual(memory.resolve("Thra"), "Thra")
        for _ in 0..<3 { _ = memory.resolve("달빛기사") }
        XCTAssertEqual(memory.resolve("달빛기시"), "달빛기시")      // Hangul is never touched
    }

    func testTheMoreFrequentReadingWins() {
        var memory = SenderMemory()
        // The misread came first: one wrong snap, then the true name takes over.
        XCTAssertEqual(memory.resolve("Thral"), "Thral")
        XCTAssertEqual(memory.resolve("Thrall"), "Thral")      // the wrong snap
        XCTAssertEqual(memory.resolve("Thrall"), "Thrall")     // equal counts: left as read
        XCTAssertEqual(memory.resolve("Thral"), "Thrall")
    }

    func testResetForgets() {
        var memory = SenderMemory()
        _ = memory.resolve("Thrall"); _ = memory.resolve("Thrall")
        memory.reset()
        XCTAssertEqual(memory.resolve("Thral"), "Thral")
    }
}
