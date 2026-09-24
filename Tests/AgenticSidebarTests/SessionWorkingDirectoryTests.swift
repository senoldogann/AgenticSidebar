import Foundation
import XCTest

@testable import AgenticSidebar

/// Oturum-klasör bağının (`workingDirectoryPath`) davranış sözleşmesi.
///
/// Kapsar: normalleştirme, klasörlü/klasörsüz başlatma, bekleyen taslakta
/// koruma/güncelleme/silme, ilk gönderimde bağın korunması, arşiv
/// round-trip ve eski arşiv uyumluluğu, boş-klasörlü oturumun saklanması,
/// dal mirası ve görünen-ad uç durumları.
@MainActor
final class SessionWorkingDirectoryTests: XCTestCase {
    // MARK: - Normalleştirme

    func testNormalizedDirectoryPathTreatsBlankAsNil() {
        XCTAssertNil(AgentSession.normalizedDirectoryPath(nil))
        XCTAssertNil(AgentSession.normalizedDirectoryPath(""))
        XCTAssertNil(AgentSession.normalizedDirectoryPath("   "))
        XCTAssertEqual(AgentSession.normalizedDirectoryPath("/tmp/proj"), "/tmp/proj")
        XCTAssertEqual(AgentSession.normalizedDirectoryPath("  /tmp/proj  "), "/tmp/proj")
    }

    func testSetWorkingDirectoryNormalizesAndDedups() {
        let session = AgentSession(runtimes: [])
        XCTAssertNil(session.workingDirectoryPath)
        session.setWorkingDirectory(path: "   ")
        XCTAssertNil(session.workingDirectoryPath)
        session.setWorkingDirectory(path: "/tmp/a")
        XCTAssertEqual(session.workingDirectoryPath, "/tmp/a")
        session.setWorkingDirectory(path: "  /tmp/a  ")
        XCTAssertEqual(session.workingDirectoryPath, "/tmp/a")
    }

    // MARK: - Başlatma

    func testCreateSessionBindsDirectory() {
        let service = AgentSessionService(runtimes: [])
        let folderID = service.createSession(workingDirectoryPath: "/tmp/proj")
        XCTAssertEqual(service.session(for: folderID)?.workingDirectoryPath, "/tmp/proj")
        XCTAssertEqual(
            service.sessionList.first(where: { $0.id == folderID })?.workingDirectoryPath,
            "/tmp/proj"
        )
    }

    func testCreateSessionWithoutDirectoryKeepsDefault() {
        let service = AgentSessionService(runtimes: [])
        let plainID = service.createSession()
        XCTAssertNil(service.session(for: plainID)?.workingDirectoryPath)
        XCTAssertNil(
            service.sessionList.first(where: { $0.id == plainID })?.workingDirectoryPath
        )
    }

    // MARK: - Bekleyen taslak sözleşmesi

    func testBeginPendingSessionBindsDirectory() {
        let service = AgentSessionService(runtimes: [])
        let pending = service.beginPendingSession(workingDirectoryPath: "/tmp/proj")
        XCTAssertEqual(service.pendingSessionID, pending)
        XCTAssertTrue(service.isPendingSessionVisible)
        XCTAssertEqual(service.session(for: pending)?.workingDirectoryPath, "/tmp/proj")
        // Liste ve kayıt değişmez: oturum doğmadı.
        XCTAssertFalse(service.sessionList.contains(where: { $0.id == pending }))
    }

    func testBeginPendingSessionNilPreservesExistingDirectory() {
        let service = AgentSessionService(runtimes: [])
        let pending = service.beginPendingSession(workingDirectoryPath: "/tmp/proj")
        // Klasörsüz çağrı mevcut taslağı olduğu gibi gösterir, klasörü silmez.
        XCTAssertEqual(service.beginPendingSession(), pending)
        XCTAssertEqual(service.session(for: pending)?.workingDirectoryPath, "/tmp/proj")
    }

    func testBeginPendingSessionWithDirectoryUpdatesExistingDraft() {
        let service = AgentSessionService(runtimes: [])
        let pending = service.beginPendingSession(workingDirectoryPath: "/tmp/eski")
        XCTAssertEqual(service.beginPendingSession(workingDirectoryPath: "/tmp/yeni"), pending)
        XCTAssertEqual(service.session(for: pending)?.workingDirectoryPath, "/tmp/yeni")
    }

    func testClearPendingSessionDirectoryKeepsDraftVisible() {
        let service = AgentSessionService(runtimes: [])
        let pending = service.beginPendingSession(workingDirectoryPath: "/tmp/proj")
        service.clearPendingSessionDirectory()
        XCTAssertEqual(service.pendingSessionID, pending)
        XCTAssertTrue(service.isPendingSessionVisible)
        XCTAssertNil(service.session(for: pending)?.workingDirectoryPath)
    }

    func testMaterializePendingSessionPreservesDirectory() {
        let service = AgentSessionService(runtimes: [])
        let pending = service.beginPendingSession(workingDirectoryPath: "/tmp/proj")
        service.materializePendingSession(pending)
        XCTAssertEqual(service.activeSessionID, pending)
        XCTAssertEqual(service.session(for: pending)?.workingDirectoryPath, "/tmp/proj")
        XCTAssertEqual(
            service.sessionList.first(where: { $0.id == pending })?.workingDirectoryPath,
            "/tmp/proj"
        )
    }

    // MARK: - Arşiv

    func testSnapshotRoundTripPreservesDirectory() {
        let session = AgentSession(runtimes: [], workingDirectoryPath: "/tmp/proj")
        let restored = AgentSession(runtimes: [], snapshot: session.snapshot())
        XCTAssertEqual(restored.workingDirectoryPath, "/tmp/proj")
    }

    func testLegacyArchiveWithoutDirectoryDecodesAsNil() throws {
        let json = """
            {"id":"\(UUID().uuidString)","createdAt":"2026-01-01T00:00:00Z","configuration":null,"messages":[]}
            """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(SessionSnapshot.self, from: json)
        XCTAssertNil(snapshot.workingDirectoryPath)
    }

    func testSaveNowKeepsFolderBoundEmptyInactiveSession() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "wd-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let store = SessionArchiveStore(fileURL: directory.appendingPathComponent("sessions.json"))
        let service = AgentSessionService(runtimes: [], archiveStore: store)
        let firstID = service.activeSessionID
        service.session(for: firstID)?.setWorkingDirectory(path: "/tmp/eski")
        let secondID = service.createSession()
        XCTAssertEqual(service.activeSessionID, secondID)

        await service.saveNow()

        guard let archive = store.load() else {
            return XCTFail("Arşiv yazılamadı")
        }
        let paths = Dictionary(
            uniqueKeysWithValues: archive.sessions.map { ($0.id, $0.workingDirectoryPath) }
        )
        XCTAssertEqual(paths[firstID], "/tmp/eski")
        XCTAssertEqual(archive.sessions.count, 2)
    }

    // MARK: - Dal

    func testForkSessionInheritsDirectoryAndDropsSummary() {
        let messages = [
            ChatMessage(role: .user, text: "Birinci soru"),
            ChatMessage(role: .assistant, text: "Birinci yanıt"),
        ]
        let service = AgentSessionService(runtimes: [], state: AgentSessionState(messages: messages))
        let sourceID = service.activeSessionID
        service.session(for: sourceID)?.setWorkingDirectory(path: "/tmp/proj")

        guard let branchID = service.forkSession(id: sourceID, throughMessageID: messages[1].id) else {
            return XCTFail("Dal oturumu açılamadı")
        }
        XCTAssertEqual(service.session(for: branchID)?.workingDirectoryPath, "/tmp/proj")
        // Özet bilinçli taşınmaz: dal kendi özetini sıfırdan üretir.
        XCTAssertEqual(service.session(for: branchID)?.contextSummary, "")
    }

    // MARK: - Görünen ad

    func testWorkingDirectoryNameEdges() {
        XCTAssertNil(WorkingDirectoryDisplay.name(for: nil))
        XCTAssertNil(WorkingDirectoryDisplay.name(for: ""))
        XCTAssertNil(WorkingDirectoryDisplay.name(for: "   "))
        XCTAssertEqual(WorkingDirectoryDisplay.name(for: "/tmp/proj"), "proj")
        // Kök yolun son bileşeni "/" döner; etiket aynen gösterir.
        XCTAssertEqual(WorkingDirectoryDisplay.name(for: "/"), "/")
    }
}
