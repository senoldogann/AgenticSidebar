import Foundation
import XCTest
@testable import AgenticSidebar

/// Snap Context: degrade katmanları, markdown biçimi ve koordinatör akışı.
///
/// Çıta: izin yoksa başlık-degrade snap kurulur, öndeki uygulama bilinmiyorsa
/// `nil` döner, kapalı ayar kısayolu yutar, açık ayar besteciye incelemeli
/// taslak bırakır (doğrudan `send()` yok).
final class ContextSnapServiceTests: XCTestCase {
    private struct StubApp: ContextFrontmostAppProvider {
        let value: (appName: String, windowTitle: String?)?
        func frontmost() -> (appName: String, windowTitle: String?)? { value }
    }

    private struct StubURL: ContextBrowserURLProvider {
        let value: String?
        func url() -> String? { value }
    }

    private struct StubText: ContextSelectedTextProvider {
        let value: String?
        func selectedText() -> String? { value }
    }

    private func service(
        app: (appName: String, windowTitle: String?)? = ("Safari", "Belge"),
        url: String? = "https://example.com/a",
        text: String? = "seçili"
    ) -> ContextSnapService {
        ContextSnapService(appProvider: StubApp(value: app), urlProvider: StubURL(value: url), textProvider: StubText(value: text))
    }

    // MARK: - Servis

    func testSnapCollectsAllLayers() {
        let snap = service().snap()

        XCTAssertEqual(snap?.appName, "Safari")
        XCTAssertEqual(snap?.windowTitle, "Belge")
        XCTAssertEqual(snap?.url, "https://example.com/a")
        XCTAssertEqual(snap?.selectedText, "seçili")
    }

    func testSnapDegradesToTitleOnlyWithoutPermissions() {
        let snap = service(app: ("Xcode", "Proje"), url: nil, text: nil).snap()

        XCTAssertEqual(snap?.appName, "Xcode")
        XCTAssertNil(snap?.url)
        XCTAssertNil(snap?.selectedText)
        XCTAssertTrue(snap?.markdown().contains("**App:** Xcode") == true)
        XCTAssertFalse(snap?.markdown().contains("**URL:**") == true)
    }

    func testSnapReturnsNilWithoutFrontmostApp() {
        XCTAssertNil(service(app: nil).snap())
    }

    func testMarkdownSkipsBlankSelectedTextAndTruncatesLongText() {
        let blank = service(text: "   \n ").snap()?.markdown()
        XCTAssertFalse(blank?.contains("**Selected:**") == true)

        let long = String(repeating: "x", count: ContextSnap.maximumSelectedCharacters + 10)
        let clipped = service(text: long).snap()?.markdown()
        XCTAssertTrue(clipped?.contains("kırpıldı") == true)
    }

    // MARK: - Koordinatör

    @MainActor
    private func coordinator(
        enabled: Bool,
        app: (appName: String, windowTitle: String?)? = ("Safari", "Belge")
    ) -> (ContextSnapCoordinator, ComposerDraftCenter) {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.context-snap")!)
        settings.contextSnapEnabled = enabled
        let drafts = ComposerDraftCenter()
        let coordinator = ContextSnapCoordinator(
            snapService: service(app: app, url: nil, text: nil),
            draftCenter: drafts,
            settings: settings,
            activeSessionID: { UUID() }
        )
        return (coordinator, drafts)
    }

    @MainActor
    func testDisabledSettingSwallowsHotKey() {
        let (coordinator, drafts) = coordinator(enabled: false)

        coordinator.handleSnapHotKey()

        XCTAssertNil(drafts.pending)
    }

    @MainActor
    func testEnabledSettingRestoresDraftForActiveSession() {
        let sessionID = UUID()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "test.context-snap")!)
        settings.contextSnapEnabled = true
        let drafts = ComposerDraftCenter()
        let coordinator = ContextSnapCoordinator(
            snapService: service(app: ("Safari", "Belge"), url: nil, text: nil),
            draftCenter: drafts,
            settings: settings,
            activeSessionID: { sessionID }
        )

        coordinator.handleSnapHotKey()

        XCTAssertEqual(drafts.pending?.sessionID, sessionID)
        XCTAssertTrue(drafts.pending?.text.contains("Safari") == true)
    }

    @MainActor
    func testHotKeyWithoutFrontmostAppLeavesNoDraft() {
        let (coordinator, drafts) = coordinator(enabled: true, app: nil)

        coordinator.handleSnapHotKey()

        XCTAssertNil(drafts.pending)
    }
}
