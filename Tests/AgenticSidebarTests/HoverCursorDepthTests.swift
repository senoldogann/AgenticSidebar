import XCTest
@testable import AgenticSidebar

/// İç içe hover bölgelerinde imleç kararının testi.
///
/// Kural, imleci doğrudan `NSCursor` üzerinden değil sayacın kararı üzerinden
/// sınanır: testin sonucu çalıştığı makinenin imleç durumuna bağlı olmamalı.
@MainActor
final class HoverCursorDepthTests: XCTestCase {
    func testNestedRegionsKeepThePointingHandUntilTheLastOneLeaves() {
        HoverCursorDepth.reset()

        XCTAssertTrue(HoverCursorDepth.enter(), "dış bölge imleci el yapar")
        XCTAssertFalse(HoverCursorDepth.enter(), "iç bölge girdiğinde imleç zaten el")
        XCTAssertFalse(
            HoverCursorDepth.exit(),
            "iç bölge çıktığında komşusunun eli korunur"
        )
        XCTAssertTrue(HoverCursorDepth.exit(), "son bölge de çıkınca ok işaretine döner")
    }

    func testRepeatedEnterForTheSameRegionDoesNotPileUp() {
        HoverCursorDepth.reset()

        XCTAssertTrue(HoverCursorDepth.enter())
        XCTAssertFalse(HoverCursorDepth.enter())
        XCTAssertFalse(HoverCursorDepth.enter())
        XCTAssertFalse(HoverCursorDepth.exit())
        XCTAssertFalse(HoverCursorDepth.exit())
        XCTAssertTrue(HoverCursorDepth.exit())
    }

    func testUnbalancedExitCannotStrandTheCursorOnTheArrow() {
        HoverCursorDepth.reset()

        XCTAssertTrue(HoverCursorDepth.exit(), "başlangıçta sıfıra düşer")
        XCTAssertTrue(HoverCursorDepth.enter(), "sonraki giriş yine el yapar")
        XCTAssertTrue(HoverCursorDepth.exit(), "ve yine ok işaretine döner")
    }
}
