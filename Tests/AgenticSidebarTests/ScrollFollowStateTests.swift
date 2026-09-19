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

    func testButtonRequiresMinimumDistanceBufferBeforeShowing() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 1_600))  // bottom: distanceFromBottom = 0

        // User scrolls up by 100 pt: away from bottom threshold (80 pt), but less than button visibility threshold (180 pt)
        state.record(snapshot: snapshot(offsetY: 1_500))
        XCTAssertTrue(state.isUserPosition)
        XCTAssertNil(state.takePending().awayFromBottom, "100 pt is below buttonVisibilityThreshold (180 pt), no button publication")

        // User scrolls up further: distanceFromBottom = 200 pt (>= 180 pt)
        state.record(snapshot: snapshot(offsetY: 1_400))
        XCTAssertEqual(state.takePending().awayFromBottom, true, "200 pt >= 180 pt triggers awayFromBottom publication")

        // User scrolls down back to 100 pt (< 180 pt)
        state.record(snapshot: snapshot(offsetY: 1_500))
        XCTAssertEqual(state.takePending().awayFromBottom, false, "dropping below 180 pt hides the button")
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

    func testAssistantMessageWhileAwayDoesNotYankButUserMessageResumes() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 0))
        state.setScrolling(false)
        XCTAssertFalse(
            state.shouldAutoFollow(now: Date()),
            "Tarihte okuyan kullanıcı yeni asistan mesajında dibe çekilmemeli"
        )
        state.resumeFollow()
        XCTAssertTrue(
            state.shouldAutoFollow(now: Date()),
            "Kullanıcının kendi mesajı takibi geri vermeli"
        )
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

    /// Inspector açılıp kapanırken genişlik animasyonu konumu sarsar.
    ///
    /// Kullanıcı dokunmadan düşen konum jest sanılmamalı: bastırma sahiplik
    /// vermez, yayın üretmez, takip dipte çalışmaya devam eder.
    func testTransientDropSuppressionIgnoresInspectorLayoutShake() {
        let state = ScrollFollowState()
        state.suppressTransientDrop()
        state.record(snapshot: snapshot(offsetY: 1_600))
        // Animasyon: kullanıcı dokunmadan konum 400 pt düşer.
        state.record(snapshot: snapshot(offsetY: 1_200))

        XCTAssertFalse(state.isUserPosition)
        XCTAssertNil(state.takePending().awayFromBottom)
        XCTAssertTrue(state.shouldAutoFollow(now: Date()))
    }

    /// Bastırma kullanıcı durumunu silmez: tarihte okuyan kullanıcı, sarsıntı
    /// sırasında da yukarıda kalır; `resumeFollow` gibi dibe döndürmez.
    func testTransientDropSuppressionPreservesScrolledUpState() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 0))
        state.setScrolling(false)
        _ = state.takePending()
        XCTAssertFalse(state.shouldAutoFollow(now: Date()))

        state.suppressTransientDrop()
        state.record(snapshot: snapshot(offsetY: 100))

        XCTAssertFalse(state.shouldAutoFollow(now: Date()))
    }

    /// Collapse kararı `isFollowing` ile verilir: canlı durum, `@State`
    /// kopyası değil. Taze durumda kullanıcı diptedir.
    func testIsFollowingStartsTrue() {
        XCTAssertTrue(ScrollFollowState().isFollowing)
    }

    /// Jest sürerken takip kapalıdır.
    func testIsFollowingFalseDuringGesture() {
        let state = ScrollFollowState()
        state.setScrolling(true)

        XCTAssertFalse(state.isFollowing)
    }

    /// 100 pt yukarıda (düğme eşiğinin altında) bile konum kullanıcıdadır:
    /// collapse dibe sabitlememeli, dokunulan başlıkta kalmalı.
    func testIsFollowingFalseAfterUserScrollsUp() {
        let state = ScrollFollowState()
        state.setScrolling(true)
        state.record(snapshot: snapshot(offsetY: 1_600))
        state.record(snapshot: snapshot(offsetY: 1_500))
        state.setScrolling(false)

        XCTAssertTrue(state.isUserPosition)
        XCTAssertFalse(state.isFollowing)
    }

    /// Collapse'in yarattığı programatik düşüş jest sanılmamalı: bastırma
    /// varken düşen konum sahiplik vermez, takip dipte sürer.
    func testCollapseDropSuppressionKeepsFollowing() {
        let state = ScrollFollowState()
        XCTAssertTrue(state.isFollowing)

        // Kullanıcı collapse'e dokunur: üst görünüm düşüş yorumunu susturur.
        state.suppressTransientDrop(for: 0.9)
        state.record(snapshot: snapshot(offsetY: 1_600))
        // Grup kapanır, içerik 300 pt kısalır, konum düşer.
        state.record(snapshot: snapshot(offsetY: 1_300))

        XCTAssertFalse(state.isUserPosition)
        XCTAssertNil(state.takePending().awayFromBottom)
        XCTAssertTrue(state.isFollowing)
        XCTAssertTrue(state.shouldAutoFollow(now: Date()))
    }

    /// Kalabalık grup listesi tembel kurulmalı: eager `VStack` 150 satırı tek
    /// turda kurup ana iş parçacığını blokluyordu.
    func testExpandedActivityListIsLazilyBuilt() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot =
            testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source =
            repoRoot
            .appendingPathComponent("Sources/AgenticSidebar/Views/AgentActivityTimelineView.swift")
        let text = try String(contentsOf: source, encoding: .utf8)

        XCTAssertTrue(
            text.contains("LazyVStack(alignment: .leading, spacing: 4)"),
            "açık grup listesi LazyVStack olmalı, yoksa 150 tool tek turda kurulur"
        )
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
            "lastAutoScrollTime",
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
    func testMessageCountScrollIsSingleFlightToTheBottomAnchor() async {
        // Üretimdeki tek uçuş sözleşmesinin aynası (ConversationDetailView
        // mesaj sayacı izleyicisi): bayat görev iptal edilir, süzgeçten
        // sonra yalnız `bottom_anchor` hedefine kayılır.
        actor DeferredBottomScrollGate {
            private var pending: Task<Void, Never>?
            private(set) var targets: [String] = []

            func schedule() {
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(40))
                    guard !Task.isCancelled else { return }
                    self.record("bottom_anchor")
                }
            }

            func settle() async {
                await pending?.value
            }

            private func record(_ target: String) {
                targets.append(target)
            }
        }

        // Canlı kaynak ağacı okunmaz: eşzamanlı düzenlemelerde kırılgan
        // dizgi eşleşmesi yerine davranış sözleşmesi denenir.
        let gate = DeferredBottomScrollGate()
        await gate.schedule()
        await gate.schedule()
        await gate.settle()

        let targets = await gate.targets
        XCTAssertEqual(
            targets,
            ["bottom_anchor"],
            "bayat görev iptal edilmeli, yalnız bottom_anchor hedefine tek kayış olmalı"
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
        let repoRoot =
            testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source =
            repoRoot
            .appendingPathComponent("Sources/AgenticSidebar/Views/ConversationDetailView.swift")

        return try String(contentsOf: source, encoding: .utf8)
    }
}
