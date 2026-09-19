import XCTest

@testable import AgenticSidebar

final class ElapsedTimeFormatterTests: XCTestCase {
    func testFormatsSecondsMinutesAndHours() {
        XCTAssertEqual(ElapsedTimeFormatter.string(seconds: 0), "0:00")
        XCTAssertEqual(ElapsedTimeFormatter.string(seconds: 65), "1:05")
        XCTAssertEqual(ElapsedTimeFormatter.string(seconds: 3_661), "1:01:01")
    }
}
