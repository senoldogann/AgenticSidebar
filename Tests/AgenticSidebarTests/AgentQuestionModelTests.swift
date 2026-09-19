import XCTest

@testable import AgenticSidebar

final class AgentQuestionModelTests: XCTestCase {
    func testOptionFormattingWithSingleChoice() {
        let options = [
            AgentQuestionOption(
                id: "opt_1",
                label: "PostgreSQL",
                description: "Production relational database",
                isRecommended: true
            ),
            AgentQuestionOption(
                id: "opt_2",
                label: "SQLite",
                description: "Local embedded database",
                isRecommended: false
            ),
        ]

        let answer = AgentQuestion.formatAnswer(
            options: options,
            selectedIDs: ["opt_1"],
            customText: nil
        )

        XCTAssertEqual(answer.selectedOptionIDs, ["opt_1"])
        XCTAssertNil(answer.customText)
        XCTAssertEqual(answer.formattedResponse, "PostgreSQL")
    }

    func testOptionFormattingWithMultipleChoicesAndCustomText() {
        let options = [
            AgentQuestionOption(
                id: "opt_1",
                label: "PostgreSQL",
                description: nil,
                isRecommended: false
            ),
            AgentQuestionOption(
                id: "opt_2",
                label: "Redis",
                description: nil,
                isRecommended: false
            ),
        ]

        let answer = AgentQuestion.formatAnswer(
            options: options,
            selectedIDs: ["opt_1", "opt_2"],
            customText: "Use Redis for caching only"
        )

        XCTAssertEqual(answer.selectedOptionIDs, ["opt_1", "opt_2"])
        XCTAssertEqual(answer.customText, "Use Redis for caching only")
        XCTAssertEqual(answer.formattedResponse, "PostgreSQL, Redis - Use Redis for caching only")
    }

    func testOptionFormattingWithCustomTextOnly() {
        let answer = AgentQuestion.formatAnswer(
            options: [],
            selectedIDs: [],
            customText: "Custom architectural decision"
        )

        XCTAssertTrue(answer.selectedOptionIDs.isEmpty)
        XCTAssertEqual(answer.customText, "Custom architectural decision")
        XCTAssertEqual(answer.formattedResponse, "Custom architectural decision")
    }

    func testParseFromToolInputWithStrings() {
        let input: [String: Any] = [
            "question": "Which framework should we use?",
            "options": [
                "Vite (Recommended)",
                "Next.js",
                "Remix",
            ],
            "allowCustomAnswer": true,
            "isMultiSelect": false,
        ]

        let parsed = AgentQuestionParser.parseFromToolInput(
            toolCallID: "call_123",
            input: input
        )

        XCTAssertNotNil(parsed)
        guard let question = parsed else { return }

        XCTAssertEqual(question.prompt, "Which framework should we use?")
        XCTAssertEqual(question.options.count, 3)
        XCTAssertEqual(question.options[0].label, "Vite (Recommended)")
        XCTAssertTrue(question.options[0].isRecommended)
        XCTAssertEqual(question.options[1].label, "Next.js")
        XCTAssertFalse(question.options[1].isRecommended)
        XCTAssertTrue(question.allowCustomAnswer)
        XCTAssertFalse(question.isMultiSelect)
        XCTAssertEqual(question.status, .pending)
    }

    func testParseFromToolInputWithOptionDictionaries() {
        let input: [String: Any] = [
            "title": "Select authorization strategy",
            "options": [
                [
                    "id": "jwt",
                    "label": "JWT Tokens",
                    "description": "Stateless bearer tokens",
                    "isRecommended": true,
                ],
                [
                    "id": "session",
                    "label": "Server Session",
                    "description": "Cookie-based stateful sessions",
                    "isRecommended": false,
                ],
            ],
            "is_multi_select": true,
        ]

        let parsed = AgentQuestionParser.parseFromToolInput(
            toolCallID: "call_456",
            input: input
        )

        XCTAssertNotNil(parsed)
        guard let question = parsed else { return }

        XCTAssertEqual(question.prompt, "Select authorization strategy")
        XCTAssertEqual(question.options.count, 2)
        XCTAssertEqual(question.options[0].id, "jwt")
        XCTAssertEqual(question.options[0].description, "Stateless bearer tokens")
        XCTAssertTrue(question.options[0].isRecommended)
        XCTAssertTrue(question.isMultiSelect)
    }

    func testParseQuickReplyOptionsFromMarkdownText() {
        let text = """
            I have analyzed your architecture. Which direction should we take?
            1. Refactor to Modular Monolith (Recommended)
            2. Split into Microservices
            3. Keep Current Structure
            """

        let options = AgentQuestionParser.parseQuickReplyOptions(from: text)
        XCTAssertEqual(options.count, 3)
        XCTAssertEqual(options[0].label, "Refactor to Modular Monolith (Recommended)")
        XCTAssertTrue(options[0].isRecommended)
        XCTAssertEqual(options[1].label, "Split into Microservices")
        XCTAssertEqual(options[2].label, "Keep Current Structure")
    }

    @MainActor
    func testAgentSessionQuestionLifecycle() {
        let session = AgentSession(
            runtimes: []
        )

        let question = AgentQuestion(
            id: UUID(),
            toolCallID: "call_test",
            prompt: "Confirm deployment?",
            options: [
                AgentQuestionOption(id: "yes", label: "Yes", description: nil, isRecommended: true),
                AgentQuestionOption(id: "no", label: "No", description: nil, isRecommended: false),
            ],
            allowCustomAnswer: true,
            isMultiSelect: false,
            createdAt: Date(),
            status: .pending
        )

        // Ask question
        session.askQuestion(question)
        XCTAssertEqual(session.state.activeQuestion?.id, question.id)
        XCTAssertEqual(session.state.activeQuestion?.status, .pending)

        // Answer question
        let answer = AgentQuestionAnswer(
            selectedOptionIDs: ["yes"],
            customText: nil,
            formattedResponse: "Yes"
        )
        session.answerActiveQuestion(answer)

        XCTAssertNil(session.state.activeQuestion)
        XCTAssertEqual(session.state.questionHistory.count, 1)
        XCTAssertEqual(session.state.questionHistory.first?.status, .answered(answer))
    }

    func testOptionFormattingWithHepsiAllOption() {
        let options = [
            AgentQuestionOption(id: "opt_1", label: "Kritik - secret ve şema", description: nil, isRecommended: true),
            AgentQuestionOption(id: "opt_2", label: "High - model çağrısı", description: nil, isRecommended: false),
            AgentQuestionOption(id: "opt_3", label: "Medium - dayanıklılık", description: nil, isRecommended: false),
        ]

        let answer = AgentQuestion.formatAnswer(
            options: options,
            selectedIDs: ["__all__"],
            customText: nil
        )

        XCTAssertEqual(answer.selectedOptionIDs, ["__all__"])
        XCTAssertTrue(answer.formattedResponse.hasPrefix("Hepsi (Tümünü uygula): "))
        XCTAssertTrue(answer.formattedResponse.contains("Kritik - secret ve şema"))
        XCTAssertTrue(answer.formattedResponse.contains("High - model çağrısı"))
        XCTAssertTrue(answer.formattedResponse.contains("Medium - dayanıklılık"))
    }

    func testParseTurkishRecommendationTags() {
        let text = """
            Sorunları çözmek için seçenekler:
            1. Kritik güvenlik açığını kapat (Önerilen)
            2. Performans iyileştirmesi yap
            3. Testleri çalıştır
            """

        let options = AgentQuestionParser.parseQuickReplyOptions(from: text)
        XCTAssertEqual(options.count, 3)
        XCTAssertTrue(options[0].isRecommended)
        XCTAssertFalse(options[1].isRecommended)
        XCTAssertFalse(options[2].isRecommended)
    }

    /// Bilgi amaçlı yanıttaki liste soru değildir: seçeneklerden sonra paragraf
    /// ve kod bloğu geliyorsa kart açılmamalı.
    func testMidMessageListWithTrailingContentIsNotAQuestion() {
        let text = """
            Mantık şöyle:
            - Developer ID Application: SENOL DOGAN
            - Apple Distribution: SENOL DOGAN
            - ComputerUse Dev
            Farklı bir kimlikle imzalamak istersen:
            ```bash
            FOO=bar ./script/build.sh
            ```
            Hiç kimlik bulunamazsa ad-hoc imzaya düşer.
            """

        XCTAssertTrue(AgentQuestionParser.parseQuickReplyOptions(from: text).isEmpty)
    }

    @MainActor
    func testQuestionSettingsInSettingsStore() {
        let store = SettingsStore()
        XCTAssertTrue(store.autoOfferAllOption)
        XCTAssertTrue(store.autoSelectRecommendedOption)

        store.autoOfferAllOption = false
        XCTAssertFalse(store.autoOfferAllOption)
        store.autoOfferAllOption = true

        store.autoSelectRecommendedOption = false
        XCTAssertFalse(store.autoSelectRecommendedOption)
        store.autoSelectRecommendedOption = true
    }
}
