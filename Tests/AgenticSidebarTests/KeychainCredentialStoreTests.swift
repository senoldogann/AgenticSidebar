import Foundation
import XCTest

@testable import AgenticSidebar

/// The one test that touches the real login keychain.
///
/// On a headless CI runner an unsigned, ad-hoc-signed test binary can be refused
/// by `SecItemAdd` or block on a prompt, which would make the whole suite's green
/// tick depend on the runner's keychain rather than on the code. It runs when
/// `RUN_KEYCHAIN_TESTS=1` is set, and skips itself otherwise so the hermetic suite
/// is what CI proves.
final class KeychainCredentialStoreTests: XCTestCase {
    func testCredentialRoundTripUpdateAndDelete() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_KEYCHAIN_TESTS"] == "1",
            "Set RUN_KEYCHAIN_TESTS=1 to exercise the real keychain"
        )

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
