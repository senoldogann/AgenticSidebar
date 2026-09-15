import Foundation
import XCTest
@testable import AgenticSidebar

final class KeychainCredentialStoreTests: XCTestCase {
    func testCredentialRoundTripUpdateAndDelete() throws {
        let service = "com.dogan.AgenticSidebar.tests.\(UUID().uuidString)"
        let store = KeychainCredentialStore(service: service)
        let firstValue = UUID().uuidString
        let secondValue = UUID().uuidString

        defer {
            try? store.delete(.openAIAPIKey)
        }

        XCTAssertFalse(try store.contains(.openAIAPIKey))
        XCTAssertNil(try store.read(.openAIAPIKey))

        try store.write(firstValue, for: .openAIAPIKey)

        XCTAssertTrue(try store.contains(.openAIAPIKey))
        XCTAssertTrue(
            try store.read(.openAIAPIKey) == firstValue,
            "Stored credential did not round-trip"
        )

        try store.write(secondValue, for: .openAIAPIKey)

        XCTAssertTrue(
            try store.read(.openAIAPIKey) == secondValue,
            "Updated credential did not replace the previous value"
        )

        try store.delete(.openAIAPIKey)

        XCTAssertFalse(try store.contains(.openAIAPIKey))
        XCTAssertNil(try store.read(.openAIAPIKey))
    }
}
