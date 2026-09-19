import AppKit
import XCTest

@testable import AgenticSidebar

@MainActor
final class NativeComposerTextViewTests: XCTestCase {
    func testShiftReturnInsertsNewlineAtCurrentSelection() throws {
        let textView = NativeComposerTextView(frame: .zero)
        textView.string = "first"
        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.submissionAvailability = .available
        textView.onSubmit = {
            XCTFail("Shift-Return must not submit the draft.")
        }

        textView.keyDown(
            with: try makeReturnEvent(modifiers: [.shift])
        )

        XCTAssertEqual(textView.string, "first\n")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 6, length: 0))
    }

    func testPlainReturnSubmitsWithoutChangingText() throws {
        let textView = NativeComposerTextView(frame: .zero)
        textView.string = "send me"
        textView.submissionAvailability = .available
        var submissionCount = 0
        textView.onSubmit = {
            submissionCount += 1
        }

        textView.keyDown(
            with: try makeReturnEvent(modifiers: [])
        )

        XCTAssertEqual(submissionCount, 1)
        XCTAssertEqual(textView.string, "send me")
    }

    func testPlainReturnIsConsumedWhenSubmissionIsUnavailable() throws {
        let textView = NativeComposerTextView(frame: .zero)
        textView.string = "   "
        textView.submissionAvailability = .unavailable
        var submissionCount = 0
        textView.onSubmit = {
            submissionCount += 1
        }

        textView.keyDown(
            with: try makeReturnEvent(modifiers: [])
        )

        XCTAssertEqual(submissionCount, 0)
        XCTAssertEqual(textView.string, "   ")
    }

    func testReturnDefersToInputMethodWhenMarkedTextIsActive() throws {
        let textView = NativeComposerTextView(frame: .zero)
        textView.submissionAvailability = .available
        var submissionCount = 0
        textView.onSubmit = {
            submissionCount += 1
        }
        textView.setMarkedText(
            "あ",
            selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )

        textView.keyDown(
            with: try makeReturnEvent(modifiers: [])
        )

        XCTAssertEqual(submissionCount, 0)
    }

    func testModelTextIsNotAppliedWhileCompositionIsActive() {
        // Arka plandaki sohbet akarken gövde tazelenir; bitmemiş hece
        // modeldeki eski metinle ezilmemeli, yoksa yazı silinir.
        XCTAssertFalse(
            ComposerTextEditor.shouldApplyModelText(
                hasMarkedText: true,
                viewString: "merha",
                modelText: "merh"
            )
        )
    }

    func testModelTextIsSkippedWhileComposingEvenWhenStringsMatch() {
        XCTAssertFalse(
            ComposerTextEditor.shouldApplyModelText(
                hasMarkedText: true,
                viewString: "merhaba",
                modelText: "merhaba"
            )
        )
    }

    func testModelTextIsAppliedWhenNothingIsComposing() {
        XCTAssertTrue(
            ComposerTextEditor.shouldApplyModelText(
                hasMarkedText: false,
                viewString: "merh",
                modelText: "merhaba"
            )
        )
    }

    func testModelTextIsSkippedWhenViewAlreadyMatches() {
        XCTAssertFalse(
            ComposerTextEditor.shouldApplyModelText(
                hasMarkedText: false,
                viewString: "merhaba",
                modelText: "merhaba"
            )
        )
    }

    private func makeReturnEvent(
        modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: modifiers,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\r",
                charactersIgnoringModifiers: "\r",
                isARepeat: false,
                keyCode: 36
            )
        )
    }
}
