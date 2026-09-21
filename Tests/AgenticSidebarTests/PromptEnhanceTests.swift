import Foundation
import XCTest

@testable import AgenticSidebar

// MARK: - Saf metin katmanı

final class PromptEnhancerTests: XCTestCase {
    func testEmptyAndBlankDraftsAreNotEnhanceable() {
        XCTAssertFalse(PromptEnhancer.isEnhanceable(""))
        XCTAssertFalse(PromptEnhancer.isEnhanceable("   \n  "))
    }

    func testSlashCommandsAreNotEnhanceable() {
        XCTAssertFalse(PromptEnhancer.isEnhanceable("/btw bu nedir?"))
        XCTAssertFalse(PromptEnhancer.isEnhanceable("/goal hedef metni"))
        XCTAssertFalse(PromptEnhancer.isEnhanceable("/compact"))
    }

    func testPlainDraftIsEnhanceable() {
        XCTAssertTrue(PromptEnhancer.isEnhanceable("hatayı düzelt"))
    }

    func testOversizedDraftIsNotEnhanceable() {
        XCTAssertFalse(
            PromptEnhancer.isEnhanceable(String(repeating: "a", count: PromptEnhancer.maximumDraftCharacters + 1))
        )
        XCTAssertTrue(
            PromptEnhancer.isEnhanceable(String(repeating: "a", count: PromptEnhancer.maximumDraftCharacters))
        )
    }

    func testInstructionKeepsDraftAndShapesForMode() {
        let instruction = PromptEnhancer.enhanceInstruction(
            draft: "testleri hızlandır",
            mode: .plan,
            tagNames: ["opencode"],
            attachmentNames: ["Hata.log"]
        )

        XCTAssertTrue(instruction.contains("testleri hızlandır"))
        XCTAssertTrue(instruction.contains(AgentMode.plan.displayName))
        XCTAssertTrue(instruction.contains("opencode"))
        XCTAssertTrue(instruction.contains("Hata.log"))
        XCTAssertTrue(instruction.contains("ONLY the improved prompt"))
    }

    func testInstructionOmitsEmptyContextSections() {
        let instruction = PromptEnhancer.enhanceInstruction(draft: "sor", mode: .build)

        XCTAssertFalse(instruction.contains("already tagged"))
        XCTAssertFalse(instruction.contains("Attached files"))
    }

    func testInstructionAsksForGoalConstraintsAndGuidance() {
        let instruction = PromptEnhancer.enhanceInstruction(draft: "özellik ekle", mode: .build)

        XCTAssertTrue(instruction.contains("goal"))
        XCTAssertTrue(instruction.contains("constraints"))
        XCTAssertTrue(instruction.contains("implementation"))
        XCTAssertTrue(instruction.contains("acceptance criteria"))
    }

    func testShouldApplyWhenDraftUnchanged() {
        XCTAssertTrue(
            PromptEnhancer.shouldApplyEnhancement(currentDraft: "hatayı düzelt", originalDraft: "hatayı düzelt")
        )
    }

    func testShouldApplyIgnoresSurroundingWhitespace() {
        XCTAssertTrue(
            PromptEnhancer.shouldApplyEnhancement(currentDraft: "  hatayı düzelt\n", originalDraft: "hatayı düzelt")
        )
    }

    func testShouldNotApplyWhenUserKeptTyping() {
        XCTAssertFalse(
            PromptEnhancer.shouldApplyEnhancement(
                currentDraft: "hatayı düzelt ve test ekle",
                originalDraft: "hatayı düzelt"
            )
        )
    }
}

// MARK: - Servis

@MainActor
final class PromptEnhanceServiceTests: XCTestCase {
    func testEnhanceStreamsAndConsumesOnce() async {
        let service = PromptEnhanceService()
        service.enhance(
            context: Self.context(),
            sessionID: UUID(),
            draft: "hatayı düzelt",
            speedMode: .normal,
            mode: .build
        )

        let finished = await Self.waitForInactive(service: service)
        XCTAssertEqual(finished?.phase, PromptEnhanceService.Phase.done)
        XCTAssertEqual(service.consumeDone(), "İyileşmiş prompt")
        XCTAssertNil(service.active)
        XCTAssertNil(service.consumeDone())
    }

    func testEnhanceRecordsOriginalDraftForRaceGuardAndUndo() async {
        let service = PromptEnhanceService()
        service.enhance(
            context: Self.context(),
            sessionID: UUID(),
            draft: "hatayı düzelt",
            speedMode: .normal,
            mode: .build
        )

        let finished = await Self.waitForInactive(service: service)
        XCTAssertEqual(finished?.phase, PromptEnhanceService.Phase.done)
        XCTAssertEqual(finished?.originalDraft, "hatayı düzelt")
    }

    func testEmptyAnswerFailsWithoutConsumableText() async {
        let service = PromptEnhanceService()
        service.enhance(
            context: Self.context(script: .empty),
            sessionID: UUID(),
            draft: "hatayı düzelt",
            speedMode: .normal,
            mode: .build
        )

        let finished = await Self.waitForInactive(service: service)
        XCTAssertEqual(finished?.phase, PromptEnhanceService.Phase.failed)
        XCTAssertFalse(finished?.errorText?.isEmpty ?? true)
        XCTAssertNil(service.consumeDone())
    }

    func testProviderFailureSurfacesActionableMessage() async {
        let service = PromptEnhanceService()
        service.enhance(
            context: Self.context(script: .failure(.missingCredential)),
            sessionID: UUID(),
            draft: "hatayı düzelt",
            speedMode: .normal,
            mode: .build
        )

        let finished = await Self.waitForInactive(service: service)
        XCTAssertEqual(finished?.phase, PromptEnhanceService.Phase.failed)
        XCTAssertTrue(finished?.errorText?.contains("API anahtarı") == true)
    }

    func testCommandDraftNeverStartsAStream() {
        let service = PromptEnhanceService()
        service.enhance(
            context: Self.context(),
            sessionID: UUID(),
            draft: "/btw bu nedir?",
            speedMode: .normal,
            mode: .build
        )

        XCTAssertNil(service.active)
        XCTAssertFalse(service.isEnhancing)
    }

    func testSecondRequestSupersedesTheFirst() async {
        let service = PromptEnhanceService()
        service.enhance(
            context: Self.context(script: .answer(["ESKİ"])),
            sessionID: UUID(),
            draft: "ilk taslak",
            speedMode: .normal,
            mode: .build
        )
        service.enhance(
            context: Self.context(script: .answer(["YENİ"])),
            sessionID: UUID(),
            draft: "ikinci taslak",
            speedMode: .normal,
            mode: .build
        )

        let finished = await Self.waitForInactive(service: service)
        XCTAssertEqual(finished?.phase, PromptEnhanceService.Phase.done)
        XCTAssertEqual(service.consumeDone(), "YENİ")
    }

    // MARK: - Kurulum

    private static func context(
        script: EnhanceScriptRuntime.Script = .answer(["İyileşmiş prompt"])
    ) -> SideQuestionContext {
        SideQuestionContext(
            runtime: EnhanceScriptRuntime(script: script),
            configuration: SessionConfiguration(
                providerID: ProviderID("stub-enhance"),
                modelID: ProviderModelID("model"),
                variantID: nil
            ),
            messages: [ChatMessage(role: .user, text: "önceki bağlam")],
            activityGroups: []
        )
    }

    private static func waitForInactive(
        service: PromptEnhanceService
    ) async -> PromptEnhanceService.ActiveEnhancement? {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let current = service.active, current.phase != .streaming {
                return current
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return service.active
    }
}

private struct EnhanceScriptRuntime: ProviderRuntime {
    enum Script: Sendable {
        case answer([String])
        case failure(ProviderRuntimeError)
        case empty
    }

    let id = ProviderID("stub-enhance")
    let script: Script

    init(script: Script = .answer(["İyileşmiş prompt"])) {
        self.script = script
    }

    func capabilities() async throws -> ProviderCapabilities {
        ProviderCapabilities(id: id, displayName: "Stub", models: [])
    }

    func startStream(for request: ProviderRequest) async throws -> ProviderStream {
        throw ProviderRuntimeError.unsupported
    }

    func answerSideQuestion(_ query: SideQuestionQuery) async throws -> ProviderStream {
        switch script {
        case .answer(let chunks):
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            for chunk in chunks {
                pair.continuation.yield(.assistantTextDelta(chunk))
            }
            pair.continuation.yield(.completed)
            pair.continuation.finish()
            return ProviderStream(events: pair.stream)
        case .failure(let error):
            throw error
        case .empty:
            let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
            pair.continuation.yield(.completed)
            pair.continuation.finish()
            return ProviderStream(events: pair.stream)
        }
    }
}
