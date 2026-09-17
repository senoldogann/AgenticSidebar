import XCTest
@testable import AgenticSidebar

/// Kaydırma takip durumunun testleri.
///
/// Buradaki sözler, çökmenin geri gelmemesini sağlayan kurallardır: ölçüm
/// toplanır, ama karar gövdeye ekran döngüsünün dışında ve yalnız değiştiğinde
/// yazılır.
@MainActor
final class ScrollFollowStateTests: XCTestCase {
    func testGestureAwayFromBottomIsPublished() {
        let state = ScrollFollowState()
        state.setScrolling(true)

        state.record(snapshot: snapshot(offsetY: 0))

        XCTAssertEqual(state.takePending().awayFromBottom, true)
    }

    func testStreamingGrowthIsNotMistakenForAnUpwardScroll() {
        let state = ScrollFollowState()

        // Jest yok: yanıt büyürken okunan konum takip modunu kapatamaz.
        state.record(snapshot: snapshot(offsetY: 0))

        XCTAssertNil(state.takePending().awayFromBottom)
    }

    /// Bir kaydırma aracının aşaması hiç bildirilmese bile konumun düşmesi
    /// yeter: fare tekerleğiyle yukarı çeken kullanıcı da takip modunu kapatır.
    func testAFallingOffsetTakesOwnershipWithoutAnyPhaseReport() {
        let state = ScrollFollowState()

        state.record(snapshot: snapshot(offsetY: 1_600))
        XCTAssertFalse(state.isUserPosition)

        state.record(snapshot: snapshot(offsetY: 1_200))

        XCTAssertTrue(state.isUserPosition)
        XCTAssertEqual(state.takePending().awayFromBottom, true)
    }

    func testResumeFollowSuppressesSpuriousOffsetDropFromDynamicInsertion() {
        let state = ScrollFollowState()
        state.resumeFollow()
        _ = state.takePending()

        state.record(snapshot: snapshot(offsetY: 1_600))
        // Simulated layout estimation glitch drops offset while user is not scrolling
        state.record(snapshot: snapshot(offsetY: 1_200))

        XCTAssertFalse(state.isUserPosition, "Spurious layout drop after resumeFollow should not take user ownership")
        XCTAssertNil(state.takePending().awayFromBottom)
    }

    func testActiveUserScrollOverridesSuppressionAfterResumeFollow() {
        let state = ScrollFollowState()
        state.resumeFollow()
        state.setScrolling(true)

        state.record(snapshot: snapshot(offsetY: 1_600))
        state.record(snapshot: snapshot(offsetY: 1_200))

        XCTAssertTrue(state.isUserPosition, "Real user gesture must immediately take ownership even during settling window")
        XCTAssertEqual(state.takePending().awayFromBottom, true)
    }

    /// Aşağı inmek takip modunu kendiliğinden açmaz: sınır geçilmediği sürece
    /// konum kullanıcının kalır, yoksa iniş sırasında yanıt onu dibe çekerdi.
    func testADescentThatHasNotReachedTheBottomKeepsFollowingOff() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 1_600))
        state.record(snapshot: snapshot(offsetY: 1_200))
        state.setScrolling(false)
        _ = state.takePending()

        state.record(snapshot: snapshot(offsetY: 1_400))

        XCTAssertFalse(state.shouldAutoFollow(now: Date()))
        XCTAssertNil(state.takePending().awayFromBottom, "sınır geçilmedi, yayın yok")
    }

    func testReturningToTheBottomBandHandsFollowingBack() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 1_600))
        state.record(snapshot: snapshot(offsetY: 1_200))

        state.record(snapshot: snapshot(offsetY: 1_580))
        state.setScrolling(false)

        XCTAssertFalse(state.isUserPosition)
        XCTAssertEqual(state.takePending().awayFromBottom, false)
        XCTAssertTrue(state.shouldAutoFollow(now: Date()))
    }

    /// Altta büyüyen içerik konumu düşürmez; düşüşün kendisi tek başına
    /// kullanıcı hareketinin kanıtıdır. Küçük ölçüm titremeleri sahiplik vermez.
    func testTinyOffsetChangesDoNotTakeOwnership() {
        let state = ScrollFollowState()

        state.record(snapshot: snapshot(offsetY: 1_600))
        state.record(snapshot: snapshot(offsetY: 1_596))

        XCTAssertFalse(state.isUserPosition)
        XCTAssertNil(state.takePending().awayFromBottom)
    }

    func testMeasurementIsPublishedOnceAndThenCleared() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 0))

        XCTAssertEqual(state.takePending().awayFromBottom, true)
        XCTAssertNil(state.takePending().awayFromBottom, "aynı ölçüm iki kez yayınlanmaz")
    }

    /// Jestin bittiği yer takip modunu belirler.
    ///
    /// Ölçüm jest sırasında kaydedilmiş olsa bile yayın bir sonraki turda
    /// yapılır; silinseydi, yukarı kaydırıp bırakan kullanıcı akan yanıtın
    /// dibe çekmesiyle karşılaşırdı.
    func testGestureEndKeepsTheFinalMeasurementForPublishing() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 0))

        state.setScrolling(false)

        XCTAssertEqual(state.takePending().awayFromBottom, true)
    }

    func testActivePromptIsQueuedRatherThanPublished() {
        let state = ScrollFollowState()
        let promptID = UUID()

        state.recordActivePrompt(promptID)

        XCTAssertEqual(state.takePending().activePromptID, promptID)
        XCTAssertNil(state.takePending().activePromptID)
    }

    func testAutoFollowWaitsForTheGestureToEnd() {
        let state = ScrollFollowState()
        state.setScrolling(true)

        XCTAssertFalse(state.shouldAutoFollow(now: Date()))
    }

    /// Ölçüm yayınlanmayı beklerken de karar geçerlidir: aksi halde jestin
    /// bitmesiyle yayın arasındaki kısa aralıkta akan yanıt dibe çekerdi.
    func testAutoFollowStopsOnceTheLastMeasurementIsAwayFromBottom() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 0))
        state.setScrolling(false)

        XCTAssertFalse(state.shouldAutoFollow(now: Date()))
    }

    func testAutoFollowResumesOnceTheUserIsBackAtTheBottom() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 0))
        state.record(snapshot: snapshot(offsetY: 1_600))
        state.setScrolling(false)

        XCTAssertTrue(state.shouldAutoFollow(now: Date()))
    }

    func testResetEnablesFollowingAgain() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 0))
        state.setScrolling(false)
        XCTAssertFalse(state.shouldAutoFollow(now: Date()))

        state.reset()

        XCTAssertTrue(state.shouldAutoFollow(now: Date()))
    }

    func testNewTurnResumesFollowingEvenAfterTheUserScrolledAway() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 0))
        state.setScrolling(false)

        state.resumeFollow()

        XCTAssertTrue(state.shouldAutoFollow(now: Date()))
    }

    func testAutoFollowIsThrottledToTheFollowInterval() {
        let state = ScrollFollowState()
        let now = Date()

        XCTAssertTrue(state.shouldAutoScroll(now: now))
        XCTAssertFalse(
            state.shouldAutoScroll(now: now.addingTimeInterval(ScrollFollowState.followInterval / 2)),
            "akan metnin her parçası bir kaydırma turu değil"
        )
        XCTAssertTrue(state.shouldAutoScroll(now: now.addingTimeInterval(ScrollFollowState.followInterval)))
    }

    func testNewTurnResumesFollowingImmediately() {
        let state = ScrollFollowState()
        let now = Date()
        _ = state.shouldAutoScroll(now: now)

        XCTAssertFalse(state.shouldAutoScroll(now: now.addingTimeInterval(0.01)))

        state.resumeFollow()

        XCTAssertTrue(state.shouldAutoScroll(now: now.addingTimeInterval(0.02)))
    }

    func testResetClearsQueuedDecisionsAndTheThrottle() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 0))
        state.recordActivePrompt(UUID())
        let now = Date()
        _ = state.shouldAutoScroll(now: now)

        state.reset()

        let pending = state.takePending()
        XCTAssertNil(pending.awayFromBottom)
        XCTAssertNil(pending.activePromptID)
        XCTAssertTrue(state.shouldAutoScroll(now: now.addingTimeInterval(0.02)))
    }

    /// Çökmenin geri gelmemesi için.
    ///
    /// Ölçümü yapan geri çağrı bir ekran döngüsünün içindedir; oradan `@State`
    /// yazmak aynı döngüde yeni bir yerleşim turu ister ve zincir kendi kendini
    /// beslediğinde AppKit tek bir döngüde yüzlerce tur sonra istisna atar.
    func testScrollCallbacksDoNotWriteViewState() throws {
        let lines = try transcriptSource().components(separatedBy: "\n")
        let callbackMarkers = ["onScrollGeometryChange", "onGeometryChange"]
        let viewStateNames = [
            "isUserScrolledUp",
            "activePromptID",
            "isUserScrolling",
            "lastAutoScrollTime"
        ]

        for (index, line) in lines.enumerated() where callbackMarkers.contains(where: line.contains) {
            for candidate in callbackBody(from: index, in: lines) {
                let code = candidate.trimmingCharacters(in: .whitespaces)
                guard let name = viewStateNames.first(where: { code.hasPrefix("\($0) =") }) else {
                    continue
                }

                XCTFail(
                    "\(name) geometri geri çağrısının içinde yazılıyor — ölçüm `ScrollFollowState`e kaydedilmeli: \(code)"
                )
            }
        }
    }

    /// Gönderim-anı kaydırma tek uçuşludur.
    ///
    /// Hızlı art arda eklemelerde (kullanıcı mesajı + asistan yer tutucusu)
    /// bayat bir `scrollTo` güncel yerleşimi ezer ve ekran boş kalırdı. Bayat
    /// görev iptal edilir, hedef yalnız `bottom_anchor` olur — yerleşmemiş bir
    /// satır kimliğine kaydırma yapılmaz.
    func testMessageCountScrollIsSingleFlightToTheBottomAnchor() throws {
        let lines = try transcriptSource().components(separatedBy: "\n")
        guard
            let handlerIndex = lines.firstIndex(where: {
                $0.contains(".onChange(of: sessionService.state.messages.count)")
            })
        else {
            XCTFail("messages.count izleyicisi bulunamadı")
            return
        }

        let body = callbackBody(from: handlerIndex, in: lines).joined(separator: "\n")
        XCTAssertTrue(
            body.contains("messageCountScrollTask?.cancel()"),
            "eski kaydırma görevi iptal edilmeli"
        )
        XCTAssertTrue(
            body.contains("proxy.scrollTo(\"bottom_anchor\""),
            "hedef bottom_anchor olmalı"
        )
        XCTAssertFalse(
            body.contains("proxy.scrollTo(lastMessageID"),
            "yerleşmemiş satır kimliğine kaydırma yapılmamalı"
        )
    }

    /// Geri çağrının kendi gövdesi: süslü parantez dengesi sıfıra dönene kadar.
    /// Sabit satır penceresi işe yaramaz — geri çağrıdan sonra gelen `.onChange`
    /// blokları da gövdeye yazar ve onlar bu kuralın dışındadır.
    private func callbackBody(from index: Int, in lines: [String]) -> ArraySlice<String> {
        var depth = 0
        var hasOpened = false

        for cursor in index..<lines.count {
            for character in lines[cursor] {
                if character == "{" {
                    depth += 1
                    hasOpened = true
                } else if character == "}" {
                    depth -= 1
                }
            }

            if hasOpened && depth <= 0 {
                return lines[index...cursor]
            }
        }

        return lines[index...]
    }

    // MARK: - Helpers

    private func snapshot(
        offsetY: CGFloat,
        contentHeight: CGFloat = 2_000,
        containerHeight: CGFloat = 400
    ) -> ChatScrollSnapshot {
        ChatScrollSnapshot(
            offsetY: offsetY,
            contentHeight: contentHeight,
            containerHeight: containerHeight
        )
    }

    private func transcriptSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = repoRoot
            .appendingPathComponent("Sources/AgenticSidebar/Views/ConversationDetailView.swift")

        return try String(contentsOf: source, encoding: .utf8)
    }
}
