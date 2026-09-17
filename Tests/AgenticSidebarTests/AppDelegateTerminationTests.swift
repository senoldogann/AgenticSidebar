import AppKit
import XCTest
@testable import AgenticSidebar

@MainActor
final class AppDelegateTerminationTests: XCTestCase {
    func testTerminationWithoutManagedShutdownCanProceedImmediately() {
        let delegate = AppDelegate()

        XCTAssertEqual(
            delegate.applicationShouldTerminate(NSApplication.shared),
            .terminateNow
        )
    }

    func testTerminationWaitsForManagedShutdownThenRepliesExactlyOnce() async {
        let delegate = AppDelegate()
        let probe = TerminationProbe()
        delegate.managedShutdown = {
            probe.shutdownCount += 1
        }
        delegate.terminationReply = { _, shouldTerminate in
            probe.replyValues.append(shouldTerminate)
        }

        let firstReply = delegate.applicationShouldTerminate(NSApplication.shared)
        let secondReply = delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(firstReply, .terminateLater)
        XCTAssertEqual(secondReply, .terminateLater)

        // 100 yield yetmezse yanlış fail olurdu; süre dolumlu bekleme yavaş
        // makinede de doğru sonucu verir.
        let deadline = ContinuousClock.now + .seconds(5)
        while probe.replyValues.isEmpty && ContinuousClock.now < deadline {
            await Task.yield()
        }

        XCTAssertEqual(probe.shutdownCount, 1)
        XCTAssertEqual(probe.replyValues, [true])
    }
}

@MainActor
private final class TerminationProbe {
    var shutdownCount = 0
    var replyValues: [Bool] = []
}
