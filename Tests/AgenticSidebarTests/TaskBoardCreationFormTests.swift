import Foundation
import XCTest

@testable import AgenticSidebar

/// Görev oluşturma formu: doğrulama, öncelik eşlemesi ve şablonlar saf
/// fonksiyonlardır; SwiftUI olmadan test edilir.
final class TaskBoardCreationFormTests: XCTestCase {

    func testBlankTitleIsRejectedWithGuidance() {
        let error = TaskCreationForm.validationError(title: "   ", objective: "Amaç yazıldı")
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("Başlık") == true)
    }

    func testBlankObjectiveIsRejectedWithGuidance() {
        let error = TaskCreationForm.validationError(title: "Başlık yazıldı", objective: "  ")
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("amaç") == true || error?.contains("Amaç") == true)
    }

    func testCompleteFormPassesValidation() {
        XCTAssertNil(TaskCreationForm.validationError(title: "Hata düzeltmesi", objective: "Kök nedeni düzelt"))
    }

    func testPriorityMappingMatchesBoardOrdering() {
        XCTAssertEqual(TaskCreationForm.priorityValue(for: .low), 0)
        XCTAssertEqual(TaskCreationForm.priorityValue(for: .normal), 1)
        XCTAssertEqual(TaskCreationForm.priorityValue(for: .high), 2)
        XCTAssertGreaterThan(
            TaskCreationForm.priorityValue(for: .high),
            TaskCreationForm.priorityValue(for: .low),
            "Yüksek öncelik panoda üstte sıralanmalı"
        )
    }

    func testTemplatesAreCompleteAndValid() {
        XCTAssertFalse(TaskCreationForm.templates.isEmpty)
        for template in TaskCreationForm.templates {
            XCTAssertFalse(template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(template.objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertFalse(template.criteria.isEmpty)
            XCTAssertNil(
                TaskCreationForm.validationError(title: template.title, objective: template.objective),
                "Şablon \(template.name) formu geçerli doldurmalı"
            )
        }
    }

    func testEmptyCallToActionOnlyForLoadedEmptyBoard() {
        XCTAssertEqual(
            TaskBoardPresenter.emptyCallToAction(cards: [], state: .loaded),
            "İlk görevi oluştur"
        )
        XCTAssertNil(TaskBoardPresenter.emptyCallToAction(cards: [], state: .idle))
        XCTAssertNil(TaskBoardPresenter.emptyCallToAction(cards: [], state: .loading))
        XCTAssertNil(
            TaskBoardPresenter.emptyCallToAction(cards: [], state: .failed(message: "hata"))
        )
    }
}
