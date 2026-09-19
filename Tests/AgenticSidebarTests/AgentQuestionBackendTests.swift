import Foundation
import XCTest

@testable import AgenticSidebar

@MainActor
final class AgentQuestionBackendTests: XCTestCase {
    func testMultiQuestionAnswersAreOrderedAndOnlyCommittedAfterBackendAccepts() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let probe = QuestionBackendProbe()
        let session = makeSession(pair: pair, probe: probe)
        let turn = try XCTUnwrap(session.submit("Choose the stack"))
        let request = OpenCodeQuestionRequest(
            requestID: "que_batch", remoteSessionID: "ses_owner", toolCallID: "call_question",
            questions: [
                OpenCodeQuestionItem(
                    prompt: "Database?", header: "DB",
                    options: [AgentQuestionOption(id: "opt_1", label: "SQLite", description: "Local", isRecommended: false)],
                    isMultiSelect: false, allowCustomAnswer: false
                ),
                OpenCodeQuestionItem(
                    prompt: "Extras?", header: "Extras",
                    options: [
                        AgentQuestionOption(id: "opt_1", label: "Redis", description: nil, isRecommended: false),
                        AgentQuestionOption(id: "opt_2", label: "Postgres", description: nil, isRecommended: false),
                    ],
                    isMultiSelect: true, allowCustomAnswer: true
                ),
            ]
        )
        pair.continuation.yield(.questionAsked(request))
        let database = await waitFor { session.state.activeQuestion?.prompt == "Database?" }
        XCTAssertTrue(database)
        XCTAssertEqual(session.state.activeQuestion?.toolCallID, "call_question")
        session.answerActiveQuestion(
            AgentQuestion.formatAnswer(
                options: request.questions[0].options, selectedIDs: ["opt_1"], customText: nil
            ))
        XCTAssertEqual(session.state.activeQuestion?.prompt, "Extras?")
        XCTAssertTrue(session.state.questionHistory.isEmpty, "A partial batch is not a backend answer")
        let callsBefore = await probe.answers()
        XCTAssertTrue(callsBefore.isEmpty)

        session.answerActiveQuestion(
            AgentQuestion.formatAnswer(
                options: request.questions[1].options,
                selectedIDs: ["opt_2", "opt_1"],
                customText: "Custom detail"
            ))
        let sent = await waitFor { await probe.answers().count == 1 }
        XCTAssertTrue(sent)
        XCTAssertNotNil(session.state.activeQuestion, "The card must remain while the server awaits its reply")
        XCTAssertTrue(session.state.questionHistory.isEmpty, "Do not claim success before the HTTP reply succeeds")
        XCTAssertTrue(session.state.isQuestionSubmitting)
        let calls = await probe.answers()
        XCTAssertEqual(calls[0].requestID, "que_batch")
        XCTAssertEqual(calls[0].answers, [["SQLite"], ["Redis", "Postgres", "Custom detail"]])

        // A second click while the HTTP request is in flight must not send a duplicate.
        session.answerActiveQuestion(
            AgentQuestion.formatAnswer(
                options: request.questions[1].options,
                selectedIDs: ["opt_1"], customText: nil
            ))
        let duplicateCalls = await probe.answers()
        XCTAssertEqual(duplicateCalls.count, 1)

        await probe.acceptReply()
        let accepted = await waitFor { session.state.activeQuestion == nil }
        XCTAssertTrue(accepted)
        XCTAssertEqual(session.state.questionHistory.count, 2)
        XCTAssertFalse(session.state.isQuestionSubmitting)
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await turn.value
    }

    func testRejectedQuestionStaysVisibleOnBackendFailureAndCanBeRetried() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let probe = QuestionBackendProbe()
        await probe.failNextRejection()
        let session = makeSession(pair: pair, probe: probe)
        let turn = try XCTUnwrap(session.submit("Confirm"))
        pair.continuation.yield(
            .questionAsked(
                OpenCodeQuestionRequest(
                    requestID: "que_cancel", remoteSessionID: "ses_owner", toolCallID: nil,
                    questions: [
                        OpenCodeQuestionItem(
                            prompt: "Proceed?", header: "Confirm", options: [],
                            isMultiSelect: false, allowCustomAnswer: true
                        )
                    ]
                )))
        let prompt = await waitFor { session.state.activeQuestion?.prompt == "Proceed?" }
        XCTAssertTrue(prompt)
        session.dismissActiveQuestion()
        let failed = await waitFor { session.state.questionSubmissionFailed }
        XCTAssertTrue(failed)
        XCTAssertNotNil(session.state.activeQuestion)
        XCTAssertTrue(session.state.questionHistory.isEmpty)
        XCTAssertFalse(session.state.isQuestionSubmitting)

        session.dismissActiveQuestion()
        let rejectedSuccessfully = await waitFor { session.state.activeQuestion == nil }
        XCTAssertTrue(rejectedSuccessfully)
        XCTAssertEqual(session.state.questionHistory.first?.status, .dismissed)
        let rejected = await probe.rejections()
        XCTAssertEqual(rejected, ["que_cancel", "que_cancel"])
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await turn.value
    }

    func testFailedReplyCanBeRetriedWithAnEditedChoice() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let probe = QuestionBackendProbe()
        await probe.failNextReply()
        let session = makeSession(pair: pair, probe: probe)
        let turn = try XCTUnwrap(session.submit("Pick a database"))
        let choices = [
            AgentQuestionOption(id: "opt_1", label: "SQLite", description: nil, isRecommended: false),
            AgentQuestionOption(id: "opt_2", label: "Postgres", description: nil, isRecommended: false),
        ]
        pair.continuation.yield(
            .questionAsked(
                OpenCodeQuestionRequest(
                    requestID: "que_retry", remoteSessionID: "ses_owner", toolCallID: nil,
                    questions: [
                        OpenCodeQuestionItem(
                            prompt: "Database?", header: "DB", options: choices,
                            isMultiSelect: false, allowCustomAnswer: false
                        )
                    ]
                )))
        let appeared = await waitFor { session.state.activeQuestion?.prompt == "Database?" }
        XCTAssertTrue(appeared)
        session.answerActiveQuestion(
            AgentQuestion.formatAnswer(
                options: choices, selectedIDs: ["opt_1"], customText: nil
            ))
        let failed = await waitFor { session.state.questionSubmissionFailed }
        XCTAssertTrue(failed)
        XCTAssertNotNil(session.state.activeQuestion)
        XCTAssertTrue(session.state.questionHistory.isEmpty)

        session.answerActiveQuestion(
            AgentQuestion.formatAnswer(
                options: choices, selectedIDs: ["opt_2"], customText: nil
            ))
        let retried = await waitFor { await probe.answers().count == 2 }
        XCTAssertTrue(retried)
        let attempts = await probe.answers()
        XCTAssertEqual(attempts.map(\.answers), [[["SQLite"]], [["Postgres"]]])
        await probe.acceptReply()
        let accepted = await waitFor { session.state.activeQuestion == nil }
        XCTAssertTrue(accepted)
        XCTAssertEqual(session.state.questionHistory.count, 1)
        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await turn.value
    }

    func testRejectingAQuestionBatchDoesNotRecordUnsentEarlierAnswers() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let probe = QuestionBackendProbe()
        let session = makeSession(pair: pair, probe: probe)
        let turn = try XCTUnwrap(session.submit("Select a stack"))
        let option = AgentQuestionOption(
            id: "opt_1", label: "SQLite", description: nil, isRecommended: false
        )
        pair.continuation.yield(
            .questionAsked(
                OpenCodeQuestionRequest(
                    requestID: "que_rejected_batch", remoteSessionID: "ses_owner", toolCallID: nil,
                    questions: [
                        OpenCodeQuestionItem(
                            prompt: "Database?", header: "Database", options: [option],
                            isMultiSelect: false, allowCustomAnswer: false
                        ),
                        OpenCodeQuestionItem(
                            prompt: "Extras?", header: "Extras", options: [],
                            isMultiSelect: false, allowCustomAnswer: true
                        ),
                    ]
                )))
        let shown = await waitFor { session.state.activeQuestion?.prompt == "Database?" }
        XCTAssertTrue(shown)
        session.answerActiveQuestion(
            AgentQuestion.formatAnswer(
                options: [option], selectedIDs: ["opt_1"], customText: nil
            ))
        XCTAssertEqual(session.state.activeQuestion?.prompt, "Extras?")
        XCTAssertTrue(session.state.questionHistory.isEmpty)

        session.dismissActiveQuestion()
        let rejected = await waitFor { session.state.activeQuestion == nil }
        XCTAssertTrue(rejected)
        let rejectedIDs = await probe.rejections()
        XCTAssertEqual(rejectedIDs, ["que_rejected_batch"])
        XCTAssertEqual(session.state.questionHistory.count, 1)
        XCTAssertEqual(session.state.questionHistory.first?.prompt, "Extras?")
        XCTAssertEqual(session.state.questionHistory.first?.status, .dismissed)

        pair.continuation.yield(.completed)
        pair.continuation.finish()
        await turn.value
    }

    func testCancellingTurnRemovesPendingQuestionAndIgnoresLateReply() async throws {
        let pair = AsyncThrowingStream<ProviderEvent, Error>.makeStream()
        let probe = QuestionBackendProbe()
        let session = makeSession(pair: pair, probe: probe)
        let turn = try XCTUnwrap(session.submit("Choose a database"))
        let option = AgentQuestionOption(
            id: "opt_1", label: "SQLite", description: nil, isRecommended: false
        )
        pair.continuation.yield(
            .questionAsked(
                OpenCodeQuestionRequest(
                    requestID: "que_cancel_turn", remoteSessionID: "ses_owner", toolCallID: nil,
                    questions: [
                        OpenCodeQuestionItem(
                            prompt: "Database?", header: "Database", options: [option],
                            isMultiSelect: false, allowCustomAnswer: false
                        )
                    ]
                )))
        let appeared = await waitFor { session.state.activeQuestion != nil }
        XCTAssertTrue(appeared)
        session.answerActiveQuestion(
            AgentQuestion.formatAnswer(
                options: [option], selectedIDs: ["opt_1"], customText: nil
            ))
        let delivered = await waitFor { await probe.answers().count == 1 }
        XCTAssertTrue(delivered)

        let cancellation = Task { await session.cancel() }
        pair.continuation.finish()
        await cancellation.value
        await turn.value

        XCTAssertNil(session.state.activeQuestion)
        XCTAssertFalse(session.state.isQuestionSubmitting)
        XCTAssertFalse(session.state.questionSubmissionFailed)
        XCTAssertEqual(session.state.status, .cancelled)
        XCTAssertTrue(session.state.questionHistory.isEmpty)

        // The backend response can finish after cancellation, but must not
        // resurrect a question or record a response for an abandoned turn.
        await probe.acceptReply()
        let stillClear = await waitFor { session.state.activeQuestion == nil }
        XCTAssertTrue(stillClear)
        XCTAssertTrue(session.state.questionHistory.isEmpty)
    }

    private func makeSession(
        pair: (stream: AsyncThrowingStream<ProviderEvent, Error>, continuation: AsyncThrowingStream<ProviderEvent, Error>.Continuation),
        probe: QuestionBackendProbe
    ) -> AgentSession {
        let runtime = TestProviderRuntime(
            id: ProviderID("opencode"), displayName: "OpenCode",
            models: [
                ProviderModelCapability(
                    id: ProviderModelID("test/model"), displayName: "Test Model", variants: []
                )
            ],
            streamFactory: { _ in
                ProviderStream(
                    events: pair.stream,
                    questionReply: { requestID, answers in
                        try await probe.reply(requestID: requestID, answers: answers)
                    },
                    questionRejection: { requestID in
                        try await probe.reject(requestID: requestID)
                    }
                )
            }
        )
        return AgentSession(
            runtimes: [runtime],
            state: AgentSessionState(
                configuration: SessionConfiguration(
                    providerID: ProviderID("opencode"),
                    modelID: ProviderModelID("test/model"), variantID: nil
                )
            ))
    }

    private func waitFor(_ condition: @escaping () async -> Bool) async -> Bool {
        for _ in 0..<600 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }
}

private actor QuestionBackendProbe {
    struct AnswerCall: Equatable, Sendable {
        let requestID: String
        let answers: [[String]]
    }

    private var answerCalls: [AnswerCall] = []
    private var replyWaiter: CheckedContinuation<Void, Never>?
    private var failReply = false
    private var rejectionCalls: [String] = []
    private var failRejection = false

    func reply(requestID: String, answers: [[String]]) async throws {
        answerCalls.append(AnswerCall(requestID: requestID, answers: answers))
        if failReply {
            failReply = false
            throw ProviderRuntimeError.transport
        }
        await withCheckedContinuation { replyWaiter = $0 }
    }

    func failNextReply() { failReply = true }

    func acceptReply() {
        replyWaiter?.resume()
        replyWaiter = nil
    }

    func answers() -> [AnswerCall] { answerCalls }

    func failNextRejection() { failRejection = true }

    func reject(requestID: String) throws {
        rejectionCalls.append(requestID)
        if failRejection {
            failRejection = false
            throw ProviderRuntimeError.transport
        }
    }

    func rejections() -> [String] { rejectionCalls }
}
