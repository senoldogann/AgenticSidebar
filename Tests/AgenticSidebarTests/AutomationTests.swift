import XCTest
@testable import AgenticSidebar

final class AutomationTests: XCTestCase {
    func testBuildIntentPromptWithExtractedText() {
        let prompt = ScreenshotMonitorService.buildIntentPrompt(
            fileName: "Screen Shot 2026-09-16.png",
            extractedText: "Solve for x: 2x + 4 = 10"
        )

        XCTAssertTrue(prompt.contains("[Screenshot captured: Screen Shot 2026-09-16.png]"))
        XCTAssertTrue(prompt.contains("Solve for x: 2x + 4 = 10"))
        XCTAssertTrue(prompt.contains("infer intent, if there is a question or problem solve it"))
    }

    func testBuildIntentPromptWithEmptyText() {
        let prompt = ScreenshotMonitorService.buildIntentPrompt(
            fileName: "diagram.png",
            extractedText: "   \n\t  "
        )

        XCTAssertTrue(prompt.contains("[Screenshot captured: diagram.png]"))
        XCTAssertTrue(prompt.contains("(No machine-readable text found in screenshot)"))
        XCTAssertTrue(prompt.contains("describe what is shown"))
    }

    func testBuildIntentPromptForExamMode() {
        let prompt = ScreenshotMonitorService.buildIntentPrompt(
            fileName: "exam_question.png",
            extractedText: "What is the derivative of sin(x)?\nA) cos(x)\nB) -cos(x)\nC) tan(x)",
            mode: .exam
        )

        XCTAssertTrue(prompt.contains("[Screenshot captured: exam_question.png]"))
        XCTAssertTrue(prompt.contains("What is the derivative of sin(x)?"))
        XCTAssertTrue(prompt.contains("EXAM SOLVER:"))
        XCTAssertTrue(prompt.contains("State the direct answer first"))
    }

    @MainActor
    func testSettingsAutomationToggles() {
        let defaultsSuite = "test.automation.settings.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: defaultsSuite)!
        let store = SettingsStore(defaults: userDefaults)

        XCTAssertFalse(store.autoSubmitClipboard)
        XCTAssertFalse(store.autoAnalyzeScreenshots)

        store.autoSubmitClipboard = true
        store.autoAnalyzeScreenshots = true

        let reloadedStore = SettingsStore(defaults: userDefaults)
        XCTAssertTrue(reloadedStore.autoSubmitClipboard)
        XCTAssertTrue(reloadedStore.autoAnalyzeScreenshots)

        userDefaults.removePersistentDomain(forName: defaultsSuite)
    }
}
