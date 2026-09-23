import Foundation
import XCTest

@testable import AgenticSidebar

/// Bağlantı kesintisi yeniden deneme kararının kapsamı: yalnız geçici
/// kopuşlar denenir, kalıcı hatalar (401, iptal, bilinmeyen) ilk denemede döner.
final class HTTPTransportRetryTests: XCTestCase {
    func testConnectivityInterruptionsAreRetried() {
        for code: URLError.Code in [
            .notConnectedToInternet,
            .networkConnectionLost,
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
        ] {
            XCTAssertTrue(
                URLSessionHTTPTransport.isConnectivityInterruption(URLError(code)),
                "Beklenen yeniden deneme kodu: \(code)"
            )
        }
    }

    func testPermanentFailuresAreNotRetried() {
        XCTAssertFalse(
            URLSessionHTTPTransport.isConnectivityInterruption(URLError(.userCancelledAuthentication))
        )
        XCTAssertFalse(
            URLSessionHTTPTransport.isConnectivityInterruption(ProviderRuntimeError.transport)
        )
        XCTAssertFalse(
            URLSessionHTTPTransport.isConnectivityInterruption(CancellationError())
        )
    }
}
