import XCTest

@testable import AgenticSidebar

final class AppIdentityTests: XCTestCase {
    func testIdentityMatchesBundleContract() {
        XCTAssertEqual(AppIdentity.name, "AgenticSidebar")
        XCTAssertEqual(AppIdentity.bundleIdentifier, "com.dogan.AgenticSidebar")
        XCTAssertEqual(AppIdentity.minimumSystemVersion, "26.0")
    }
}
