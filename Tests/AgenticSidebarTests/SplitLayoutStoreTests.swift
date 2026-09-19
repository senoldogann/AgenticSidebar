import Foundation
import XCTest

@testable import AgenticSidebar

/// Yan yana sohbet düzeni tek bir kurala dayanır: iki bölme asla aynı
/// oturumu göstermez, silinen oturum bölmede kalamaz.
final class SplitLayoutStoreTests: XCTestCase {
    @MainActor
    private func makeStore() -> (SplitLayoutStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "test-split-\(UUID().uuidString)")!
        return (SplitLayoutStore(userDefaults: defaults), defaults)
    }

    @MainActor
    func testStartsSingle() {
        let (store, _) = makeStore()
        XCTAssertFalse(store.isSideBySide)
        XCTAssertNil(store.secondarySessionID)
    }

    @MainActor
    func testOpenSecondaryPinsADifferentSession() {
        let (store, _) = makeStore()
        let primary = UUID()
        let secondary = UUID()
        store.openSecondary(secondary, primary: primary)
        XCTAssertTrue(store.isSideBySide)
        XCTAssertEqual(store.secondarySessionID, secondary)
    }

    @MainActor
    func testOpenSecondaryIgnoresThePrimarySession() {
        let (store, _) = makeStore()
        let primary = UUID()
        store.openSecondary(primary, primary: primary)
        XCTAssertFalse(store.isSideBySide)
        XCTAssertNil(store.secondarySessionID)
    }

    @MainActor
    func testToggleClosesAnAlreadyPinnedSession() {
        let (store, _) = makeStore()
        let primary = UUID()
        let secondary = UUID()
        store.toggleSecondary(secondary, primary: primary)
        XCTAssertEqual(store.secondarySessionID, secondary)
        store.toggleSecondary(secondary, primary: primary)
        XCTAssertNil(store.secondarySessionID)
        XCTAssertFalse(store.isSideBySide)
    }

    @MainActor
    func testValidateDropsADeletedSecondarySession() {
        let (store, _) = makeStore()
        let primary = UUID()
        let secondary = UUID()
        store.openSecondary(secondary, primary: primary)
        store.validate(liveIDs: [primary], primary: primary)
        XCTAssertNil(store.secondarySessionID)
    }

    @MainActor
    func testValidateDropsSecondaryWhenItBecomesPrimary() {
        let (store, _) = makeStore()
        let first = UUID()
        let second = UUID()
        store.openSecondary(second, primary: first)
        store.validate(liveIDs: [first, second], primary: second)
        XCTAssertNil(store.secondarySessionID)
        XCTAssertFalse(store.isSideBySide)
    }

    @MainActor
    func testSplitFractionIsClamped() {
        let (store, _) = makeStore()
        store.setSplitFraction(0.9)
        XCTAssertEqual(store.splitFraction, 0.75, accuracy: 0.001)
        store.setSplitFraction(0.05)
        XCTAssertEqual(store.splitFraction, 0.25, accuracy: 0.001)
        store.setSplitFraction(0.4)
        XCTAssertEqual(store.splitFraction, 0.4, accuracy: 0.001)
    }

    @MainActor
    func testSecondarySessionSurvivesARelaunch() {
        let defaults = UserDefaults(suiteName: "test-split-\(UUID().uuidString)")!
        let secondary = UUID()
        let first = SplitLayoutStore(userDefaults: defaults)
        first.openSecondary(secondary, primary: UUID())
        let second = SplitLayoutStore(userDefaults: defaults)
        XCTAssertEqual(second.secondarySessionID, secondary)
        XCTAssertTrue(second.isSideBySide)
    }

    // MARK: - Dörtlü ızgara

    /// Üç sabit yuva birbirinden farklı oturum tutar.
    @MainActor
    func testQuadPinsThreeDistinctSessions() {
        let (store, _) = makeStore()
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        store.pin(second, to: .secondary)
        store.pin(third, to: .tertiary)
        store.pin(fourth, to: .quaternary)
        XCTAssertEqual(store.sessionID(for: .secondary), second)
        XCTAssertEqual(store.sessionID(for: .tertiary), third)
        XCTAssertEqual(store.sessionID(for: .quaternary), fourth)
        XCTAssertEqual(store.pinnedSessionIDs, [second, third, fourth])
    }

    /// Birincil yuva sabitlenemez: aktif oturumu izler.
    @MainActor
    func testPinToPrimaryIsIgnored() {
        let (store, _) = makeStore()
        let id = UUID()
        store.pin(id, to: .primary)
        XCTAssertNil(store.sessionID(for: .primary))
        XCTAssertTrue(store.pinnedSessionIDs.isEmpty)
    }

    /// Oturum başka yuvadaysa içerikler takas olur, iki bölme aynı sohbeti göstermez.
    @MainActor
    func testPinSwapsOccupants() {
        let (store, _) = makeStore()
        let second = UUID()
        let third = UUID()
        store.pin(second, to: .secondary)
        store.pin(third, to: .tertiary)
        store.pin(second, to: .tertiary)
        XCTAssertEqual(store.sessionID(for: .tertiary), second)
        XCTAssertEqual(store.sessionID(for: .secondary), third)
    }

    /// Dolu hedefe yeni oturum sabitlenince yerinden edilen ilk boş yuvaya geçer.
    @MainActor
    func testPinDisplacedOccupantMovesToFreeSlot() {
        let (store, _) = makeStore()
        let second = UUID()
        let newcomer = UUID()
        store.pin(second, to: .secondary)
        store.pin(newcomer, to: .secondary)
        XCTAssertEqual(store.sessionID(for: .secondary), newcomer)
        XCTAssertEqual(store.sessionID(for: .tertiary), second)
    }

    /// Doğrulama birincil oturumu HER sabit yuvadan düşürür, yalnız ikincilden değil.
    @MainActor
    func testValidateDropsPrimaryDuplicateInAnySlot() {
        let (store, _) = makeStore()
        let primary = UUID()
        let other = UUID()
        store.pin(primary, to: .tertiary)
        store.pin(other, to: .quaternary)
        store.pin(primary, to: .secondary)
        store.validate(liveIDs: [primary, other], primary: primary)
        XCTAssertNil(store.sessionID(for: .secondary))
        XCTAssertNil(store.sessionID(for: .tertiary))
        XCTAssertEqual(store.sessionID(for: .quaternary), other)
    }

    /// Yinelenen oturumda ilk yuva kazanır, sonrakiler düşer.
    /// (`pin` takasla yinelenmeyi önler; bu durum yalnız saklı kayıt
    /// bozulmasıyla oluşur, o yüzden doğrudan kalıcılıktan kurulur.)
    @MainActor
    func testValidateKeepsFirstDuplicateDropsLater() {
        let defaults = UserDefaults(suiteName: "test-split-\(UUID().uuidString)")!
        let primary = UUID()
        let dup = UUID()
        defaults.set(
            ["secondary:\(dup.uuidString)", "quaternary:\(dup.uuidString)"],
            forKey: "SplitLayout.slots"
        )
        let store = SplitLayoutStore(userDefaults: defaults)
        store.validate(liveIDs: [primary, dup], primary: primary)
        // İkincil ilk yuva olduğu için korunur, dördüncül düşer.
        XCTAssertEqual(store.sessionID(for: .secondary), dup)
        XCTAssertNil(store.sessionID(for: .quaternary))
    }

    /// Kip değişimi sohbet kapatmaz, kalıcılıkta yaşar.
    @MainActor
    func testLayoutModePersistsAcrossRelaunch() {
        let defaults = UserDefaults(suiteName: "test-split-\(UUID().uuidString)")!
        let first = SplitLayoutStore(userDefaults: defaults)
        first.setLayoutMode(.quad)
        let second = SplitLayoutStore(userDefaults: defaults)
        XCTAssertEqual(second.layoutMode, .quad)
    }

    /// Izgara ayraç oranları sınırlanır ve kalıcılıkta yaşar.
    @MainActor
    func testGridFractionsAreClampedAndPersisted() {
        let defaults = UserDefaults(suiteName: "test-split-\(UUID().uuidString)")!
        let first = SplitLayoutStore(userDefaults: defaults)
        first.setColumnFraction(0.9)
        first.setRowFraction(0.05)
        XCTAssertEqual(first.columnFraction, 0.75, accuracy: 0.001)
        XCTAssertEqual(first.rowFraction, 0.25, accuracy: 0.001)
        first.setColumnFraction(0.4)
        first.setRowFraction(0.6)
        let second = SplitLayoutStore(userDefaults: defaults)
        XCTAssertEqual(second.columnFraction, 0.4, accuracy: 0.001)
        XCTAssertEqual(second.rowFraction, 0.6, accuracy: 0.001)
    }

    /// Yuvalar yeniden başlatmada korunur.
    @MainActor
    func testAllSlotsSurviveARelaunch() {
        let defaults = UserDefaults(suiteName: "test-split-\(UUID().uuidString)")!
        let second = UUID()
        let third = UUID()
        let fourth = UUID()
        let first = SplitLayoutStore(userDefaults: defaults)
        first.pin(second, to: .secondary)
        first.pin(third, to: .tertiary)
        first.pin(fourth, to: .quaternary)
        first.setLayoutMode(.quad)
        let reloaded = SplitLayoutStore(userDefaults: defaults)
        XCTAssertEqual(reloaded.sessionID(for: .secondary), second)
        XCTAssertEqual(reloaded.sessionID(for: .tertiary), third)
        XCTAssertEqual(reloaded.sessionID(for: .quaternary), fourth)
        XCTAssertEqual(reloaded.layoutMode, .quad)
    }

    /// Eski ikili kayıt dörtlü modele göçer: ikincil yuva dolar, kip ikili olur.
    @MainActor
    func testLegacySecondaryKeyMigrates() {
        let defaults = UserDefaults(suiteName: "test-split-\(UUID().uuidString)")!
        let secondary = UUID()
        defaults.set(secondary.uuidString, forKey: "SplitLayout.secondarySessionID")
        let store = SplitLayoutStore(userDefaults: defaults)
        XCTAssertEqual(store.sessionID(for: .secondary), secondary)
        XCTAssertEqual(store.layoutMode, .dual)
    }

    /// Dörtlü kipte yuva boşaltma kipi düşürmez.
    @MainActor
    func testUnpinSlotInQuadKeepsMode() {
        let (store, _) = makeStore()
        store.setLayoutMode(.quad)
        store.pin(UUID(), to: .secondary)
        store.pin(UUID(), to: .tertiary)
        store.unpinSlot(.tertiary)
        XCTAssertEqual(store.layoutMode, .quad)
        XCTAssertNil(store.sessionID(for: .tertiary))
    }

    /// Odaklanan yuva HUD takibini belirler; silinen odak aktife düşer.
    @MainActor
    func testResolvedFocusSessionFallsBackWhenPinnedIsGone() {
        let (store, _) = makeStore()
        let active = UUID()
        let pinned = UUID()
        store.pin(pinned, to: .tertiary)
        store.focus(.tertiary)
        XCTAssertEqual(
            store.resolvedFocusSessionID(activeID: active, liveIDs: [active, pinned]),
            pinned
        )
        XCTAssertEqual(
            store.resolvedFocusSessionID(activeID: active, liveIDs: [active]),
            active
        )
    }
}
