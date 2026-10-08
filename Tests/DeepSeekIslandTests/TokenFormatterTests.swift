import XCTest
@testable import DeepSeekIsland

final class TokenFormatterTests: XCTestCase {
    func testCompactUnitsAtBoundaries() {
        XCTAssertEqual(TokenFormatter.short(0), "0万")
        XCTAssertEqual(TokenFormatter.short(1), "<0.01万")
        XCTAssertEqual(TokenFormatter.short(100), "0.01万")
        XCTAssertEqual(TokenFormatter.short(12_345), "1.23万")
        XCTAssertEqual(TokenFormatter.short(123_456), "12.3万")
        XCTAssertEqual(TokenFormatter.short(1_234_567), "123万")
        XCTAssertEqual(TokenFormatter.short(9_999_999), "999万")
        XCTAssertEqual(TokenFormatter.short(10_000_000), "0.1亿")
        XCTAssertEqual(TokenFormatter.short(12_345_678), "0.12亿")
        XCTAssertEqual(TokenFormatter.short(100_000_000), "1亿")
        XCTAssertEqual(TokenFormatter.short(123_456_789), "1.23亿")
    }
}
