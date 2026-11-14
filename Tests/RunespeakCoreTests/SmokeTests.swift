import XCTest
@testable import RunespeakCore

final class SmokeTests: XCTestCase {
    func testDefaultSettingsRoundTrip() throws {
        let s = AppSettings()
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data), s)
    }
}
