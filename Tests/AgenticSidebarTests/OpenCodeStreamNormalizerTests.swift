import XCTest

@testable import AgenticSidebar

final class OpenCodeStreamNormalizerTests: XCTestCase {
    func testTextDeltaArrivingBeforePartTypeIsBufferedThenFlushed() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_1","field":"text","delta":"Hel"}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_1","sessionID":"ses_target","messageID":"msg_1","type":"text","text":"Hel"},"time":1}}"#
            ),
            [.assistantTextDelta("Hel")]
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_1","field":"text","delta":"lo"}}"#
            ),
            [.assistantTextDelta("lo")]
        )
    }

    /// Kullanıcının kendi mesajı asistan metni olarak yayılmaz.
    ///
    /// OpenCode kullanıcının mesajını da parça olarak yayar ve o parçanın metni
    /// gönderilen çerçeveli prompt'un aynısıdır; rol ayrımı olmadan sohbete
    /// `<user_turn>…</user_turn>` bir asistan yanıtı gibi düşüyordu.
    func testUserMessagePartsAreNeverEmittedAsAssistantText() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.updated","properties":{"info":{"id":"msg_user","sessionID":"ses_target","role":"user"}}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_user","sessionID":"ses_target","messageID":"msg_user","type":"text","text":"<user_turn>Fix the bug</user_turn>"},"time":1}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_user","partID":"prt_user","field":"text","delta":"leak"}}"#
            ),
            []
        )
    }

    /// Rol öğrenildikten sonra asistan parçaları akmaya devam eder.
    func testAssistantPartsStillStreamAfterRoleTracking() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        for line in [
            #"data: {"type":"message.updated","properties":{"info":{"id":"msg_user","sessionID":"ses_target","role":"user"}}}"#,
            #"data: {"type":"message.updated","properties":{"info":{"id":"msg_asst","sessionID":"ses_target","role":"assistant"}}}"#,
        ] {
            XCTAssertEqual(try normalizer.consume(line: line), [])
        }

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_a","sessionID":"ses_target","messageID":"msg_asst","type":"text","text":"Hel"},"time":1}}"#
            ),
            [.assistantTextDelta("Hel")]
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_asst","partID":"prt_a","field":"text","delta":"lo"}}"#
            ),
            [.assistantTextDelta("lo")]
        )
    }

    /// Başka bir oturumun kullanıcı mesajı bu turun parçalarını susturmaz.
    func testUserMessageRoleFromAForeignSessionIsIgnored() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.updated","properties":{"info":{"id":"msg_other","sessionID":"ses_other","role":"user"}}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_x","sessionID":"ses_target","messageID":"msg_other","type":"text","text":"Hel"},"time":1}}"#
            ),
            [.assistantTextDelta("Hel")]
        )
    }

    /// Biten asistan mesajının jeton sayımı tur kullanımı olarak yayılır:
    /// sunucu tarafı oturumun o adımdaki girdi sayımı, bağlam boyutunun
    /// gerçek karşılığıdır.
    func testAssistantMessageTokensAreEmittedAsTurnUsage() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.updated","properties":{"info":{"id":"msg_asst","sessionID":"ses_target","role":"assistant","tokens":{"input":48210,"output":1204,"reasoning":300,"cache":{"read":40000,"write":0}},"cost":0.012}}}"#
            ),
            [.turnUsage(TurnTokenUsage(inputTokens: 48210, outputTokens: 1204))]
        )
    }

    func testAssistantMessageWithoutTokensEmitsNothing() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.updated","properties":{"info":{"id":"msg_asst","sessionID":"ses_target","role":"assistant"}}}"#
            ),
            []
        )
    }

    func testForeignAssistantTokensAreIgnored() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.updated","properties":{"info":{"id":"msg_asst","sessionID":"ses_other","role":"assistant","tokens":{"input":48210,"output":1204}}}}"#
            ),
            []
        )
    }

    /// Reasoning asistan metni olarak yayılmaz — ayrı thinking kanalına akar.
    ///
    /// Düşünme içeriği cevaba karışmamalı ama çöpe de gitmemeli: turdaki
    /// düşünme kartını doldurur, transkripte yazılmaz.
    func testReasoningDeltaIsNeverExposedAsAssistantText() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_reason","field":"text","delta":"private reasoning"}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_reason","sessionID":"ses_target","messageID":"msg_1","type":"reasoning","text":"private reasoning","time":{"start":1}},"time":1}}"#
            ),
            [.thinkingDelta("private reasoning")]
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_reason","field":"text","delta":" more"}}"#
            ),
            [.thinkingDelta(" more")]
        )
    }

    /// Akışsız gelen bütün reasoning parçası tek seferlik thinking'e taşınır;
    /// tekrarı sessizce düşer.
    func testReasoningFullTextWithoutDeltasEmitsThinkingOnce() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        let line =
            #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_reason","sessionID":"ses_target","messageID":"msg_1","type":"reasoning","text":"full thought","time":{"start":1}},"time":1}}"#
        XCTAssertEqual(
            try normalizer.consume(line: line),
            [.thinkingDelta("full thought")]
        )
        XCTAssertEqual(try normalizer.consume(line: line), [])
    }

    /// Akmış reasoning deltası bütün-metin güncellemesiyle ikilenmez.
    func testReasoningStreamedDeltasAreNotDuplicatedByFullText() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_reason","sessionID":"ses_target","messageID":"msg_1","type":"reasoning","text":"","time":1}}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_reason","field":"text","delta":"Hel"}}"#
            ),
            [.thinkingDelta("Hel")]
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_reason","sessionID":"ses_target","messageID":"msg_1","type":"reasoning","text":"Hello","time":2}}}"#
            ),
            []
        )
    }

    func testToolRunningAndCompletedMapToProviderEvents() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_tool","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"read","state":{"status":"running","input":{},"time":{"start":1}}},"time":1}}"#
            ),
            [
                .activityStarted(
                    ProviderActivityDescriptor(
                        id: ProviderActivityID("prt_tool"),
                        kind: .read
                    )
                )
            ]
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_tool","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"read","state":{"status":"completed","input":{},"output":"ok","title":"done","metadata":{},"time":{"start":1,"end":2}}},"time":2}}"#
            ),
            [
                .activityFinished(
                    ProviderActivityID("prt_tool"),
                    outcome: .completed,
                    output: "ok"
                )
            ]
        )
    }

    func testToolErrorMapsToFailedActivityOutcome() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        _ = try normalizer.consume(
            line:
                #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_tool","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"edit","state":{"status":"running","input":{},"time":{"start":1}}},"time":1}}"#
        )

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_tool","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"edit","state":{"status":"error","input":{},"error":"backend detail","time":{"start":1,"end":2}}},"time":2}}"#
            ),
            [
                .activityFinished(
                    ProviderActivityID("prt_tool"),
                    outcome: .failed,
                    output: "backend detail"
                )
            ]
        )
    }

    func testTargetSessionIdleCompletesAndUnrelatedSessionIsIgnored() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"session.status","properties":{"sessionID":"ses_other","status":{"type":"idle"}}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"session.status","properties":{"sessionID":"ses_target","status":{"type":"busy"}}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"session.status","properties":{"sessionID":"ses_target","status":{"type":"idle"}}}"#
            ),
            [.completed]
        )
    }

    func testTargetSessionErrorThrowsUnexpectedResponse() {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertThrowsError(
            try normalizer.consume(
                line:
                    #"data: {"type":"session.error","properties":{"sessionID":"ses_target","error":{"name":"UnknownError","data":{"message":"sensitive backend detail"}}}}"#
            )
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .unexpectedResponse)
        }
    }

    func testContextOverflowErrorIsReportedAsAnActionableCause() {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertThrowsError(
            try normalizer.consume(
                line:
                    #"data: {"type":"session.error","properties":{"sessionID":"ses_target","error":{"name":"ContextOverflowError","data":{"message":"Input exceeds the context window"}}}}"#
            )
        ) { error in
            XCTAssertEqual(error as? ProviderRuntimeError, .contextLimitExceeded)
        }
    }

    func testSSEControlLinesAndUnknownEventsAreIgnored() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(try normalizer.consume(line: ""), [])
        XCTAssertEqual(try normalizer.consume(line: "event: message.part.delta"), [])
        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"server.connected","properties":{}}"#
            ),
            []
        )
    }

    func testSSEDataWithoutOptionalSpaceStillDeliversCompletion() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line: #"data:{"type":"session.idle","properties":{"sessionID":"ses_target"}}"#
            ),
            [.completed]
        )
    }

    func testPermissionAskedInvokesCallbackWithStructuredRequest() throws {
        final class RequestBox: @unchecked Sendable {
            var value: OpenCodePermissionRequest?
        }
        let box = RequestBox()
        var normalizer = OpenCodeStreamNormalizer(
            sessionID: "ses_target",
            onPermissionRequest: { request in
                box.value = request
            }
        )

        // A global /event subscription also sees unrelated conversations.
        let otherSession = try normalizer.consume(
            line:
                #"data: {"type":"permission.asked","properties":{"sessionID":"ses_other","id":"per_other","permission":"chatgpt-system_computer_click"}}"#
        )
        XCTAssertEqual(otherSession, [])
        XCTAssertNil(box.value, "Foreign session requests have no verified owner")

        let events = try normalizer.consume(
            line:
                #"data: {"type":"permission.asked","properties":{"sessionID":"ses_target","id":"per_12345","permission":"chatgpt-system_computer_click","patterns":["*"],"always":["chatgpt-system_computer_click*"],"metadata":{"description":"Click the Run button"}}}"#
        )
        XCTAssertEqual(events, [])
        XCTAssertEqual(
            box.value,
            OpenCodePermissionRequest(
                id: "per_12345",
                remoteSessionID: "ses_target",
                toolName: "chatgpt-system_computer_click",
                patterns: ["*"],
                alwaysPatterns: ["chatgpt-system_computer_click*"],
                detail: "description: Click the Run button"
            )
        )
    }

    /// A delegated session's request is delivered (the exemption above) *and*
    /// labelled, because the prompt has to say who is asking: the same question
    /// from a subagent is not the same thing as from the agent being talked to.
    func testTheTurnsOwnRequestIsNotMarkedAsDelegated() throws {
        final class RequestBox: @unchecked Sendable {
            var value: OpenCodePermissionRequest?
        }
        let box = RequestBox()
        var normalizer = OpenCodeStreamNormalizer(
            sessionID: "ses_target",
            onPermissionRequest: { request in
                box.value = request
            }
        )

        _ = try normalizer.consume(
            line:
                #"data: {"type":"permission.asked","properties":{"sessionID":"ses_target","id":"per_own","permission":"bash","patterns":["ls"],"always":[]}}"#
        )

        XCTAssertEqual(box.value?.isDelegatedSession, false)

        // The parent task's backend metadata is the evidence of ownership.
        _ = try normalizer.consume(
            line:
                #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_task","type":"tool","tool":"task","state":{"status":"running","input":{},"metadata":{"sessionId":"ses_child"}}}}}"#
        )
        _ = try normalizer.consume(
            line:
                #"data: {"type":"permission.asked","properties":{"sessionID":"ses_child","id":"per_child","permission":"external_directory","patterns":["/tmp/*"],"always":[]}}"#
        )

        XCTAssertEqual(box.value?.isDelegatedSession, true)
        XCTAssertEqual(box.value?.remoteSessionID, "ses_child")
    }

    func testForeignPermissionWaitsForVerifiedSubagentOwnership() throws {
        final class RequestBox: @unchecked Sendable {
            var requests: [OpenCodePermissionRequest] = []
        }
        let box = RequestBox()
        var normalizer = OpenCodeStreamNormalizer(
            sessionID: "ses_target",
            onPermissionRequest: { box.requests.append($0) }
        )

        // /event is global. Never attribute a foreign conversation's request.
        _ = try normalizer.consume(
            line:
                #"data: {"type":"permission.asked","properties":{"sessionID":"ses_foreign","id":"per_foreign","permission":"bash","patterns":["rm -rf *"]}}"#
        )
        XCTAssertTrue(box.requests.isEmpty)

        // A delegated child can ask before the task publishes its identity.
        _ = try normalizer.consume(
            line:
                #"data: {"type":"permission.asked","properties":{"sessionID":"ses_child","id":"per_child","permission":"bash","patterns":["swift test"]}}"#
        )
        XCTAssertTrue(box.requests.isEmpty)

        _ = try normalizer.consume(
            line:
                #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_task","type":"tool","tool":"task","state":{"status":"running","input":{"subagent_type":"explore"},"metadata":{"sessionId":"ses_child"}}}}}"#
        )
        XCTAssertEqual(box.requests.map(\.id), ["per_child"])
        XCTAssertEqual(box.requests.first?.remoteSessionID, "ses_child")
        XCTAssertEqual(box.requests.first?.isDelegatedSession, true)
    }

    func testPermissionAskedWithoutPermissionNameIsIgnored() throws {
        final class RequestBox: @unchecked Sendable {
            var value: OpenCodePermissionRequest?
        }
        let box = RequestBox()
        var normalizer = OpenCodeStreamNormalizer(
            sessionID: "ses_target",
            onPermissionRequest: { request in
                box.value = request
            }
        )

        let events = try normalizer.consume(
            line: #"data: {"type":"permission.asked","properties":{"sessionID":"ses_target","id":"per_12345"}}"#
        )

        XCTAssertEqual(events, [])
        XCTAssertNil(box.value)
    }
}

final class SubagentStreamNormalizerTests: XCTestCase {
    func testTaskToolRunningStartsASubagentActivity() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_task","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"task","state":{"status":"running","input":{"description":"Research auth flow","prompt":"Find how login works","subagent_type":"explore"},"time":{"start":1}}},"time":1}}"#
            ),
            [
                .activityStarted(
                    ProviderActivityDescriptor.sanitizedTool(
                        id: ProviderActivityID("prt_task"),
                        toolName: "task",
                        title: "Delegated to explore: Research auth flow",
                        detail: "Find how login works",
                        output: nil
                    )
                )
            ]
        )
    }

    func testTaskToolCompletionCarriesOnlyTheReport() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        _ = try normalizer.consume(
            line:
                #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_task","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"task","state":{"status":"running","input":{"description":"Research auth flow","subagent_type":"explore"},"time":{"start":1}}},"time":1}}"#
        )

        // Çocuk oturumun araç olayı: eşleme henüz bilinmediği için tamponda bekler.
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_child","part":{"id":"prt_child_read","sessionID":"ses_child","messageID":"msg_c","type":"tool","callID":"call_c","tool":"read","state":{"status":"completed","input":{"filePath":"Sources/Session.swift"},"time":{"start":1,"end":2}}},"time":2}}"#
            ),
            []
        )

        // Çocuk kimliğini açıklayan güncelleme tamponu boşaltır ve adımı yayınlar.
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_task","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"task","state":{"status":"running","input":{"description":"Research auth flow","subagent_type":"explore"},"metadata":{"sessionId":"ses_child"},"time":{"start":1}}},"time":3}}"#
            ),
            [
                .activityUpdated(
                    ProviderActivityDescriptor.sanitizedTool(
                        id: ProviderActivityID("prt_task"),
                        toolName: "task",
                        title: "Delegated to explore: Research auth flow",
                        detail: "1 tool call · last: Read",
                        output: "Subagent explore working (1 step):\n✓ Read — Analyzed Session.swift"
                    )
                )
            ]
        )

        // Bitişte kart adım listesini bırakır; nihai rapor sarmalayıcıdan
        // soyulmuş hâlde tek başına taşınır.
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_task","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"task","state":{"status":"completed","input":{"description":"Research auth flow","subagent_type":"explore"},"output":"<task_result>Login uses OAuth.</task_result>","title":"Research auth flow","metadata":{"sessionId":"ses_child"},"time":{"start":1,"end":4}}},"time":4}}"#
            ),
            [
                .activityUpdated(
                    ProviderActivityDescriptor.sanitizedTool(
                        id: ProviderActivityID("prt_task"),
                        toolName: "task",
                        title: "Delegated to explore: Research auth flow",
                        detail: "1 tool call · last: Read",
                        output: "Subagent explore ran (1 step):\n✓ Read — Analyzed Session.swift"
                    )
                ),
                .activityFinished(
                    ProviderActivityID("prt_task"),
                    outcome: .completed,
                    output: "Login uses OAuth."
                ),
            ]
        )
    }

    func testTaskToolCompletionStripsTheFullTaskWrapper() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        _ = try normalizer.consume(
            line:
                #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_task","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"task","state":{"status":"running","input":{"description":"Research auth flow","subagent_type":"explore"},"time":{"start":1}}},"time":1}}"#
        )

        let events = try normalizer.consume(
            line:
                #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_task","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"task","state":{"status":"completed","input":{"description":"Research auth flow","subagent_type":"explore"},"output":"<task id=\"ses_child\" state=\"completed\">\n\n<task_result>\n\nRapor:\n- madde\n\n</task_result>\n</task>","title":"Research auth flow","metadata":{"sessionId":"ses_child"},"time":{"start":1,"end":4}}},"time":4}}"#
        )

        let finished = events.compactMap { event -> String? in
            if case .activityFinished(_, _, let output, _) = event {
                return output
            }
            return nil
        }

        XCTAssertEqual(finished, ["Rapor:\n- madde"])
    }

    func testMCPToolRunningShowsServerAndTool() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_mcp","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"mcp__github__get_user","state":{"status":"running","input":{"username":"octocat"},"time":{"start":1}}},"time":1}}"#
            ),
            [
                .activityStarted(
                    ProviderActivityDescriptor.sanitizedTool(
                        id: ProviderActivityID("prt_mcp"),
                        toolName: "mcp__github__get_user",
                        title: "Get User via github",
                        detail: "MCP · github",
                        output: nil
                    )
                )
            ]
        )
    }

    func testEmptyDataSSELineReturnsEmptyEvents() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(try normalizer.consume(line: "data:"), [])
        XCTAssertEqual(try normalizer.consume(line: "data: "), [])
        XCTAssertEqual(try normalizer.consume(line: "data:    \t  "), [])
    }

    func testSubagentPrefixStrippingInNormalizer() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        let events = try normalizer.consume(
            line:
                #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_sub","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_sub","tool":"subagent_explore","state":{"status":"running","time":{"start":1}}},"time":1}}"#
        )

        XCTAssertEqual(
            events,
            [
                .activityStarted(
                    ProviderActivityDescriptor.sanitizedTool(
                        id: ProviderActivityID("prt_sub"),
                        toolName: "subagent_explore",
                        title: "Delegated to explore",
                        detail: "explore",
                        output: nil
                    )
                )
            ]
        )
    }

    func testTaskToolLiveStepsFollowChildToolEvents() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        _ = try normalizer.consume(
            line:
                #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_task","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_1","tool":"task","state":{"status":"running","input":{"description":"Research auth flow","subagent_type":"explore"},"metadata":{"sessionId":"ses_child"},"time":{"start":1}}},"time":1}}"#
        )

        // Çocuk araç başlıyor: adım "…" ile görünür.
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_child","part":{"id":"prt_child_bash","sessionID":"ses_child","messageID":"msg_c","type":"tool","callID":"call_c","tool":"bash","state":{"status":"running","input":{"command":"swift build"},"time":{"start":1}}},"time":2}}"#
            ),
            [
                .activityUpdated(
                    ProviderActivityDescriptor.sanitizedTool(
                        id: ProviderActivityID("prt_task"),
                        toolName: "task",
                        title: "Delegated to explore: Research auth flow",
                        detail: "1 tool call · last: Bash",
                        output: "Subagent explore working (1 step):\n… Bash — Running swift build"
                    )
                )
            ]
        )

        // Araç bitince aynı satır "✓" olur.
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_child","part":{"id":"prt_child_bash","sessionID":"ses_child","messageID":"msg_c","type":"tool","callID":"call_c","tool":"bash","state":{"status":"completed","input":{"command":"swift build"},"output":"ok","time":{"start":1,"end":2}}},"time":3}}"#
            ),
            [
                .activityUpdated(
                    ProviderActivityDescriptor.sanitizedTool(
                        id: ProviderActivityID("prt_task"),
                        toolName: "task",
                        title: "Delegated to explore: Research auth flow",
                        detail: "1 tool call · last: Bash",
                        output: "Subagent explore working (1 step):\n✓ Bash — Ran swift build"
                    )
                )
            ]
        )

        // İkinci araç listeye eklenir.
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_child","part":{"id":"prt_child_read","sessionID":"ses_child","messageID":"msg_c","type":"tool","callID":"call_c2","tool":"read","state":{"status":"running","input":{"filePath":"Sources/App.swift"},"time":{"start":3}}},"time":4}}"#
            ),
            [
                .activityUpdated(
                    ProviderActivityDescriptor.sanitizedTool(
                        id: ProviderActivityID("prt_task"),
                        toolName: "task",
                        title: "Delegated to explore: Research auth flow",
                        detail: "2 tool calls · last: Read",
                        output: "Subagent explore working (2 steps):\n✓ Bash — Ran swift build\n… Read — Analyzed App.swift"
                    )
                )
            ]
        )

        // Eşlemesi olmayan bir oturumun olayı karta hiçbir şey yazmaz.
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_other","part":{"id":"prt_other","sessionID":"ses_other","messageID":"msg_o","type":"tool","callID":"call_o","tool":"bash","state":{"status":"completed","input":{"command":"echo other"},"time":{"start":1,"end":2}}},"time":5}}"#
            ),
            []
        )
    }

    func testDirectToolCompletionEmitsStartedAndFinishedEvents() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        let events = try normalizer.consume(
            line:
                #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_fast","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_fast","tool":"bash","state":{"status":"completed","input":{"command":"ls -la"},"output":"file.txt","time":{"start":1,"end":2}}},"time":2}}"#
        )

        XCTAssertEqual(
            events,
            [
                .activityStarted(
                    ProviderActivityDescriptor.sanitizedTool(
                        id: ProviderActivityID("prt_fast"),
                        toolName: "bash",
                        title: "Ran ls -la",
                        detail: "ls -la",
                        output: "file.txt"
                    )
                ),
                .activityFinished(
                    ProviderActivityID("prt_fast"),
                    outcome: .completed,
                    output: "file.txt"
                ),
            ]
        )

        // Duplicate completion event for the same part ID is ignored
        let duplicateEvents = try normalizer.consume(
            line:
                #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_fast","sessionID":"ses_target","messageID":"msg_1","type":"tool","callID":"call_fast","tool":"bash","state":{"status":"completed","input":{"command":"ls -la"},"output":"file.txt","time":{"start":1,"end":2}}},"time":2}}"#
        )
        XCTAssertEqual(duplicateEvents, [])
    }
}

/// Runtime lifecycle (T3): an unrelated turn must survive foreign backend
/// noise, complete text parts must surface, and turn-bounded buffers stay
/// bounded no matter how many part IDs a turn invents.
final class OpenCodeStreamNormalizerLifecycleTests: XCTestCase {
    func testSessionErrorWithoutSessionIDIsIgnored() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line: #"data: {"type":"session.error","properties":{"error":{"name":"UnknownError","data":{"message":"boom"}}}}"#
            ),
            [],
            "A session.error that names no session cannot be attributed to this turn"
        )
    }

    func testSessionErrorForAnotherSessionIsIgnored() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"session.error","properties":{"sessionID":"ses_other","error":{"name":"UnknownError","data":{"message":"boom"}}}}"#
            ),
            []
        )
    }

    func testTextPartUpdateWithoutBufferedDeltaEmitsInlineText() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_1","sessionID":"ses_target","messageID":"msg_1","type":"text","text":"Direct"},"time":1}}"#
            ),
            [.assistantTextDelta("Direct")]
        )
    }

    func testStreamedDeltasAreNotDuplicatedByLaterFullTextUpdate() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        // Creation update learns the part type; its text is still empty.
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_1","sessionID":"ses_target","messageID":"msg_1","type":"text","text":""},"time":1}}"#
            ),
            []
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_1","field":"text","delta":"Hel"}}"#
            ),
            [.assistantTextDelta("Hel")]
        )
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.delta","properties":{"sessionID":"ses_target","messageID":"msg_1","partID":"prt_1","field":"text","delta":"lo"}}"#
            ),
            [.assistantTextDelta("lo")]
        )
        // A later update carrying the full text must not re-emit what streamed.
        XCTAssertEqual(
            try normalizer.consume(
                line:
                    #"data: {"type":"message.part.updated","properties":{"sessionID":"ses_target","part":{"id":"prt_1","sessionID":"ses_target","messageID":"msg_1","type":"text","text":"Hello"},"time":2}}"#
            ),
            []
        )
    }

    func testBufferedTextDeltasAreCappedAndEvictOldest() throws {

        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        for index in 0..<130 {
            let events = try normalizer.consume(
                line:
                    "data: {\"type\":\"message.part.delta\",\"properties\":{\"sessionID\":\"ses_target\",\"messageID\":\"msg_1\",\"partID\":\"prt_\(index)\",\"field\":\"text\",\"delta\":\"t\(index)\"}}"
            )
            XCTAssertEqual(events, [])
        }

        let events = try normalizer.consume(
            line: #"data: {"type":"session.idle","properties":{"sessionID":"ses_target"}}"#
        )
        let texts = events.compactMap { event -> String? in
            if case .assistantTextDelta(let text) = event { return text }
            return nil
        }

        XCTAssertEqual(events.last, .completed)
        XCTAssertEqual(texts.count, 128, "Turn-bounded text buffers must not grow without bound")
        XCTAssertEqual(texts.first, "t2", "Eviction drops the oldest buffered parts first")
        XCTAssertEqual(texts.last, "t129")
    }

    func testFinishedToolPartIDsEvictOldest() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        for index in 0..<260 {
            let events = try normalizer.consume(line: Self.toolCompletionLine(index: index))
            XCTAssertEqual(events.count, 2, "A direct completion emits started and finished")
        }

        // The oldest IDs fell out of the capped set: their late duplicate is
        // processed again instead of being dropped.
        let reemitted = try normalizer.consume(line: Self.toolCompletionLine(index: 0))
        XCTAssertEqual(reemitted.count, 2)
        // A recent ID is still remembered: its duplicate stays silent.
        XCTAssertEqual(
            try normalizer.consume(line: Self.toolCompletionLine(index: 259)),
            []
        )
    }

    private static func toolCompletionLine(index: Int) -> String {
        "data: {\"type\":\"message.part.updated\",\"properties\":{\"sessionID\":\"ses_target\",\"part\":{\"id\":\"prt_\(index)\",\"sessionID\":\"ses_target\",\"messageID\":\"msg_1\",\"type\":\"tool\",\"callID\":\"call_\(index)\",\"tool\":\"read\",\"state\":{\"status\":\"completed\",\"input\":{},\"output\":\"ok\",\"time\":{\"start\":1,\"end\":2}}},\"time\":2}}"
    }

    func testEmittedTextPartIDsEvictOldest() throws {
        var normalizer = OpenCodeStreamNormalizer(sessionID: "ses_target")

        for index in 0..<260 {
            XCTAssertEqual(
                try normalizer.consume(line: Self.completeTextLine(index: index)),
                [.assistantTextDelta("t\(index)")]
            )
        }

        // The oldest IDs fell out of the capped set: the same complete part
        // emits again instead of staying silent.
        XCTAssertEqual(
            try normalizer.consume(line: Self.completeTextLine(index: 0)),
            [.assistantTextDelta("t0")]
        )
        // A recent ID is still remembered: its repeat stays silent.
        XCTAssertEqual(
            try normalizer.consume(line: Self.completeTextLine(index: 259)),
            []
        )
    }

    private static func completeTextLine(index: Int) -> String {
        "data: {\"type\":\"message.part.updated\",\"properties\":{\"sessionID\":\"ses_target\",\"part\":{\"id\":\"prt_\(index)\",\"sessionID\":\"ses_target\",\"messageID\":\"msg_1\",\"type\":\"text\",\"text\":\"t\(index)\"},\"time\":2}}"
    }
}
