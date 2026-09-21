import Foundation
import XCTest

@testable import AgenticSidebar

/// Kapalı grup özeti önizlemesi: koşan varsa en son koşan, yoksa en son
/// aktivite, boş listede `nil`.
final class AgentActivityTimelinePreviewTests: XCTestCase {
    private func activity(id: String, kind: ProviderActivityKind, phase: AgentActivityPhase) -> AgentActivity {
        AgentActivity(
            id: ProviderActivityID(id),
            kind: kind,
            phase: phase,
            title: id,
            detail: nil,
            output: nil,
            diff: nil,
            startedAt: Date(),
            completedAt: phase == .running ? nil : Date()
        )
    }

    func testPrefersMostRecentRunningActivity() {
        let activities = [
            activity(id: "a", kind: .read, phase: .completed),
            activity(id: "b", kind: .command, phase: .running),
            activity(id: "c", kind: .webSearch, phase: .running),
        ]
        XCTAssertEqual(
            AgentActivityTimelineView.collapsedPreviewActivity(from: activities)?.id.rawValue,
            "c"
        )
    }

    func testFallsBackToLastActivityWhenNothingRunning() {
        let activities = [
            activity(id: "a", kind: .read, phase: .completed),
            activity(id: "b", kind: .command, phase: .completed),
        ]
        XCTAssertEqual(
            AgentActivityTimelineView.collapsedPreviewActivity(from: activities)?.id.rawValue,
            "b"
        )
    }

    func testEmptyListHasNoPreview() {
        XCTAssertNil(AgentActivityTimelineView.collapsedPreviewActivity(from: []))
    }

    /// Canlı başlık üstteyken listede yalnız bitenler kalır: koşan iş iki
    /// kez görünmez, bitince listeye döner.
    func testFinishedActivitiesExcludesRunning() {
        let activities = [
            activity(id: "a", kind: .read, phase: .completed),
            activity(id: "b", kind: .command, phase: .running),
        ]
        let finished = AgentActivityTimelineView.finishedActivities(from: activities)
        XCTAssertEqual(finished.map(\.id.rawValue), ["a"])
    }

    func testFinishedActivitiesKeepsAllWhenIdle() {
        let activities = [
            activity(id: "a", kind: .read, phase: .completed),
            activity(id: "b", kind: .command, phase: .completed),
        ]
        XCTAssertEqual(
            AgentActivityTimelineView.finishedActivities(from: activities).map(\.id.rawValue),
            ["a", "b"]
        )
    }

    /// Var olan görsel dosya önizlemeye çözülür.
    func testComputerImageURLResolvesExistingImageFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".png")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: Data([0x89, 0x50])))
        defer { try? FileManager.default.removeItem(at: url) }

        var shot = activity(id: "s", kind: .computer, phase: .completed)
        shot.output = "Screenshot\n\(url.path)"
        XCTAssertEqual(AgentActivityTimelineView.computerImageURL(for: shot), url)
        // Görsel yolu metin kartından çıkarılır, kalan metin kalır.
        XCTAssertEqual(
            AgentActivityTimelineView.computerTextOutput(for: shot, imageURL: url),
            "Screenshot"
        )
    }

    /// Olmayan yol görsel sayılmaz, çıktı metin kartına gider.
    func testComputerImageURLIgnoresMissingFiles() {
        var shot = activity(id: "s", kind: .computer, phase: .completed)
        shot.output = "Screenshot\n/tmp/olmayan-ekran-goruntusu.png"
        XCTAssertNil(AgentActivityTimelineView.computerImageURL(for: shot))
        XCTAssertEqual(
            AgentActivityTimelineView.computerTextOutput(for: shot, imageURL: nil),
            "Screenshot\n/tmp/olmayan-ekran-goruntusu.png"
        )
    }

    /// Bitmiş düşünme parçaları listede çağrıldıkları yerde durur: her
    /// reasoning bloğu kendi satırını kurar, tek blokta toplanmaz.
    func testFinishedActivitiesKeepsThinkingSegmentsInPosition() {
        let activities = [
            activity(id: "t0", kind: .thinking, phase: .completed),
            activity(id: "a", kind: .command, phase: .completed),
            activity(id: "t1", kind: .thinking, phase: .completed),
        ]
        XCTAssertEqual(
            AgentActivityTimelineView.finishedActivities(from: activities).map(\.id.rawValue),
            ["t0", "a", "t1"]
        )
    }

    /// Genişletilmiş liste koşarken yalnız bitenleri kaydırır (koşan iş üstte
    /// sabit düğmededir), boşluktaysa tamamını gösterir. İçerik seçimi
    /// `ScrollView` kimliğinden ayrıdır: koşu geçişinde liste yıkılıp
    /// yeniden kurulmaz, kaydırma konumu korunur.
    func testDisplayedActivitiesLiveShowsFinishedOnly() {
        let activities = [
            activity(id: "a", kind: .command, phase: .completed),
            activity(id: "b", kind: .command, phase: .running),
        ]
        XCTAssertEqual(
            AgentActivityTimelineView.displayedActivities(from: activities, isLiveRunning: true)
                .map(\.id.rawValue),
            ["a"]
        )
    }

    func testDisplayedActivitiesIdleShowsAll() {
        let activities = [
            activity(id: "a", kind: .command, phase: .completed),
            activity(id: "b", kind: .command, phase: .completed),
        ]
        XCTAssertEqual(
            AgentActivityTimelineView.displayedActivities(from: activities, isLiveRunning: false)
                .map(\.id.rawValue),
            ["a", "b"]
        )
    }

    /// Bitmiş Thought parlamaz ve saniye saatini dinlemez: shimmer ve
    /// `SecondTick` yalnız koşan düşünme dalındadır. Eski sürüm turdaki
    /// araçlar koşarken bitmiş Thought'u da her saniye yeniden kuruyordu;
    /// süre `completedAt` ile donmuşken zamanlayıcı boşuna dönüyordu.
    func testCompletedThoughtHasNoShimmer() throws {
        let source = try timelineSource()
        XCTAssertFalse(
            source.contains("thinking.phase == .running || hasRunningChildren"),
            "Bitmiş Thought SecondTick ile tiklememeli"
        )
        XCTAssertTrue(
            source.contains(".sunshineShimmer(isActive: true)"),
            "Koşan düşünme sunshine ile parlamalı"
        )
        XCTAssertFalse(
            source.contains("sunshineShimmer(isActive: thinking.phase"),
            "Bitmiş Thought'a koşullu shimmer taşınmamalı"
        )
    }

    /// Parlama harf-içidir: maske kayan bandın değil overlay'in tamamınadır,
    /// yoksa metin banda sıkışıp düz çizgi gibi görünür.
    func testShimmerMaskCoversFullOverlay() throws {
        let source = try timelineSource()
        XCTAssertTrue(
            source.contains(".mask { content }"),
            "Parlama alttaki metnin harf formlarından görünmeli"
        )
    }

    /// Genişletilmiş grupta tek kayan alan: koşan varken/yokken ayrı
    /// `ScrollView` kurulursa tool'lar arası boşlukta konum sıfırlanır.
    func testExpandedGroupUsesSingleScrollView() throws {
        let source = try timelineSource()
        XCTAssertTrue(
            source.contains("Self.displayedActivities("),
            "Genişletilmiş liste tek ScrollView'da içerik seçmeli"
        )
    }

    private func timelineSource() throws -> String {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let source =
            testsDirectory
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AgenticSidebar/Views/AgentActivityTimelineView.swift")
        return try String(contentsOf: source, encoding: .utf8)
    }
}
