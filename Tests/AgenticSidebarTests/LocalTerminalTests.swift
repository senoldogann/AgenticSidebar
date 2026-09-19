import AppKit
import Darwin
import Foundation
import XCTest

@testable import AgenticSidebar

/// Gömülü kabuk: ANSI temizliği saf fonksiyondur, kabuk yaşam döngüsü
/// bölme başına merkezde durur.
final class LocalTerminalTests: XCTestCase {
    /// A queued write must never run against a descriptor closed by stop().
    /// Hold the serial queue so shutdown/write ordering is deterministic.
    func testQueuedTerminalWritesAreDiscardedAndDescriptorClosesInQueueOrder() async {
        let pipe = Pipe()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let queue = DispatchQueue(label: "terminal-write-shutdown-regression")
        queue.suspend()
        let writer = TerminalQueuedInput(handle: pipe.fileHandleForWriting, queue: queue)
        writer.write(Data("stale input".utf8))
        writer.close()
        XCTAssertNotEqual(fcntl(descriptor, F_GETFD), -1, "close must wait behind queued writes")

        let drained = expectation(description: "serial writer drained")
        queue.async { drained.fulfill() }
        queue.resume()
        await fulfillment(of: [drained], timeout: 3)
        XCTAssertEqual(fcntl(descriptor, F_GETFD), -1, "the descriptor must eventually close")
        XCTAssertTrue(pipe.fileHandleForReading.readDataToEndOfFile().isEmpty, "stale input must be discarded")
        try? pipe.fileHandleForReading.close()
    }

    func testPlainTextStripsAnsiSequences() {
        let plain = LocalTerminalService.plainText(
            from: "\u{1B}[32mgreen\u{1B}[0m plain \u{1B}[1;34mblue\u{1B}[0m"
        )
        XCTAssertEqual(plain, "green plain blue")
    }

    func testPlainTextNormalizesLineEndings() {
        let plain = LocalTerminalService.plainText(from: "one\r\ntwo\rthree\n")
        XCTAssertEqual(plain, "one\ntwo\nthree\n")
    }

    func testPlainTextKeepsOrdinaryTextVerbatim() {
        let text = "drwxr-xr-x  3 dogan  staff  96 Sep 17 23:59 Desktop\n"
        XCTAssertEqual(LocalTerminalService.plainText(from: text), text)
    }

    /// Başlangıç satırı iki hatta da düşer: görünüm yalnız biçimli hattı
    /// gösterir, boş ekran + yeşil nokta bu ikisi ayrışınca olur.
    @MainActor
    func testStartPopulatesStyledOutput() {
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.start()
        XCTAssertTrue(service.isRunning)
        XCTAssertTrue(
            service.styledOutput.string.contains("Terminal ready"),
            "unexpected styled output: \(service.styledOutput.string.suffix(200))"
        )
        service.stop()
        XCTAssertFalse(service.isRunning)
    }

    /// Koordinatör biçimli çıktıyı metin deposuna işler: `sync` sessizce
    /// dönerse ekran yeşil noktaya rağmen boş kalır.
    @MainActor
    func testCoordinatorSyncAppendsToTextStorage() {
        let textView = TerminalEmulatorTextView()
        let coordinator = TerminalTTYView.Coordinator()
        let styled = AnsiStyleParser.styled("Terminal ready · /tmp\n")
        coordinator.sync(styled: styled, textView: textView)
        XCTAssertTrue(
            textView.string.contains("Terminal ready"),
            "unexpected text: \(textView.string.suffix(200))"
        )
        // İkinci parça öneki koruyup eki ekler, başı tekrarlamaz.
        let more = NSMutableAttributedString(attributedString: styled)
        more.append(AnsiStyleParser.styled("second line\n"))
        coordinator.sync(styled: more, textView: textView)
        XCTAssertTrue(textView.string.contains("second line"))
        XCTAssertEqual(textView.string.components(separatedBy: "Terminal ready").count - 1, 1)
    }

    @MainActor
    func testCenterReturnsTheSameShellPerTab() {
        let center = TerminalServiceCenter()
        let directory = FileManager.default.temporaryDirectory
        let first = center.service(for: "terminal:primary", workingDirectory: directory)
        let second = center.service(for: "terminal:primary", workingDirectory: directory)
        XCTAssertTrue(first === second)
        let other = center.service(for: "terminal:secondary", workingDirectory: directory)
        XCTAssertFalse(first === other)
        center.close(id: "terminal:primary")
        center.close(id: "terminal:secondary")
        XCTAssertFalse(first.isRunning)
    }

    /// Gövde-içi bakış sözlüğe yazmaz: `existing` yokken `nil` döner, `service`
    /// ile ısıtılınca aynı örneği verir. Gövde artık buradan okur, yazmaz.
    @MainActor
    func testCenterExistingReadsWithoutCreating() {
        let center = TerminalServiceCenter()
        XCTAssertNil(center.existing(id: "terminal:primary"))
        let created = center.service(
            for: "terminal:primary",
            workingDirectory: FileManager.default.temporaryDirectory
        )
        XCTAssertTrue(center.existing(id: "terminal:primary") === created)
        center.close(id: "terminal:primary")
    }

    /// Var olmayan dizin kabuğu sessizce öldürüyordu (boş ekran): geçici
    /// dizine düşülür, böylece karşılama her zaman görünür.
    func testEffectiveWorkingDirectoryFallsBackWhenMissing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("yok-boyle-bir-dizin-\(UUID().uuidString)")
        XCTAssertEqual(
            LocalTerminalService.effectiveWorkingDirectory(for: missing),
            FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(
            LocalTerminalService.effectiveWorkingDirectory(
                for: FileManager.default.temporaryDirectory
            ),
            FileManager.default.temporaryDirectory
        )
    }

    func testTerminalChildEnvironmentDoesNotInheritSecrets() {
        setenv("AGENTICSIDEBAR_TEST_SECRET_XYZ", "s3cr3t", 1)
        defer { unsetenv("AGENTICSIDEBAR_TEST_SECRET_XYZ") }
        let environment = FoundationOpenCodeProcessLauncher.childEnvironment(overrides: [
            "TERM": "xterm-256color",
            "COLUMNS": "120",
            "LINES": "40",
        ])
        XCTAssertNil(
            environment["AGENTICSIDEBAR_TEST_SECRET_XYZ"],
            "Pty çocuğu sürecin tamamını değil izin listesini almalı"
        )
        XCTAssertNil(environment["GITHUB_TOKEN"])
        XCTAssertEqual(environment["TERM"], "xterm-256color")
        XCTAssertEqual(environment["COLUMNS"], "120")
        XCTAssertEqual(environment["LINES"], "40")
    }

    /// Gerçek kabuk: komut gönderilir, çıktısı okunur. `script` yoksa atlanır.
    @MainActor
    func testShellRunsACommand() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
            return
        }
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.start()
        XCTAssertTrue(service.isRunning)
        service.send("printf 'terminal-result-%s done\\n' 42")
        let deadline = Date().addingTimeInterval(15)
        while !service.output.contains("terminal-result-42 done"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(
            service.output.contains("terminal-result-42 done"),
            "unexpected output: \(service.output.suffix(500))"
        )
        service.stop()
        XCTAssertFalse(service.isRunning)
    }

    /// Ham yol: satır sonu eklenmeden yazılan yazı pty yankısıyla geri döner.
    /// Tab/ok tuşları bu yoldan geçtiği için Tab-tamamlamanın taşıyıcısıdır.
    @MainActor
    func testSendRawEchoesThroughPty() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
            return
        }
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.start()
        XCTAssertTrue(service.isRunning)
        service.sendRaw("raw-echo-probe")
        let deadline = Date().addingTimeInterval(15)
        while !service.output.contains("raw-echo-probe"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(
            service.output.contains("raw-echo-probe"),
            "unexpected output: \(service.output.suffix(500))"
        )
        // Ham yazı tek başına komut çalıştırmaz: satır sonu yoktur.
        service.sendData(Data("\n".utf8))
        service.stop()
        XCTAssertFalse(service.isRunning)
    }

    /// Hata akışı da ekrana gelir: gerçek Terminal'de olduğu gibi `ls`
    /// olmayan-dizin hatası çıktı hattında görünür, çöpe gitmez.
    @MainActor
    func testShellShowsStderrOutput() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/script") else {
            return
        }
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.start()
        XCTAssertTrue(service.isRunning)
        service.send("ls /yok-boyle-bir-dizin-agentic-sidebar-xyz")
        let deadline = Date().addingTimeInterval(15)
        while !service.output.contains("yok-boyle-bir-dizin-agentic-sidebar-xyz"), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(
            service.output.contains("yok-boyle-bir-dizin-agentic-sidebar-xyz"),
            "unexpected output: \(service.output.suffix(500))"
        )
        service.stop()
        XCTAssertFalse(service.isRunning)
    }

    /// Raporlanan sapma: `cd` yazımı `ccd` görünüyordu. `zsh` satır düzenleyici
    /// her tuşta satırı baştan çizer: `c` yankısından sonra `\x08` + `cd` gelir.
    /// Geri-al işlenmeyip metinde görünmez kalınca ekranda çift harf duruyordu.
    @MainActor
    func testTypingEchoWithBackspaceRedrawShowsSingleCharacters() {
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.emitText("dogan@mac ~ % ")
        service.emitText("c")
        service.emitText("\u{08}cd")
        XCTAssertEqual(service.output, "dogan@mac ~ % cd")
        XCTAssertEqual(service.styledOutput.string, "dogan@mac ~ % cd")
    }

    /// Yalın `\r` satır sonu değil satırbaşıdır: kabuk istemi ve ilerleme
    /// çıktıları `\r` ile satırı baştan çizer; `\n` yapılınca her tuş yeni
    /// satır demekti.
    @MainActor
    func testCarriageReturnRewritesTheCurrentLine() {
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.emitText("hello\rbye")
        XCTAssertEqual(service.output, "bye")
        XCTAssertEqual(service.styledOutput.string, "bye")
    }

    /// pty satır sonu her zaman `\r\n` gelir; tek satır sonu sayılır, satır
    /// içeriği kaybolmaz.
    @MainActor
    func testCarriageReturnNewlinePairStaysASingleNewline() {
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.emitText("a\rb\r\nc")
        XCTAssertEqual(service.output, "b\nc")
        XCTAssertEqual(service.styledOutput.string, "b\nc")
    }

    /// Satır başındaki geri-al dokunmaz: satır sonunu yemez, çökmez.
    @MainActor
    func testBackspaceAtLineStartIsANoOp() {
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.emitText("\u{08}\u{08}x")
        XCTAssertEqual(service.output, "x")
        XCTAssertEqual(service.styledOutput.string, "x")
    }

    /// Geri-al satır sonunu geçmez: önceki satır korunur.
    @MainActor
    func testBackspaceDoesNotCrossNewlines() {
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.emitText("a\nb\u{08}\u{08}")
        XCTAssertEqual(service.output, "a\n")
        XCTAssertEqual(service.styledOutput.string, "a\n")
    }

    /// Zil (`\x07`) sese karşılık gelir, ekranda iz bırakmaz.
    @MainActor
    func testBellIsDropped() {
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.emitText("a\u{07}b")
        XCTAssertEqual(service.output, "ab")
        XCTAssertEqual(service.styledOutput.string, "ab")
    }

    /// Parça sınırında bölünen kaçış düz hatta sızmaz: biçimli hat yarım
    /// diziyi bekletirken düz hat `ESC[3` parçasını metne katıyordu.
    @MainActor
    func testTrailingPartialEscapeDoesNotLeakIntoPlainOutput() {
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.emitText("\u{1B}[3")
        XCTAssertEqual(service.output, "")
        service.emitText("1mred")
        XCTAssertEqual(service.output, "red")
        XCTAssertEqual(service.styledOutput.string, "red")
    }

    /// Biçim durumu denetim baytlarını aşar: renk, geri-al/satırbaşı
    /// op'larından etkilenmeden sürer.
    @MainActor
    func testStyleStateSurvivesControlBytes() {
        let service = LocalTerminalService(
            workingDirectory: FileManager.default.temporaryDirectory
        )
        service.emitText("\u{1B}[31mred\u{08}d")
        XCTAssertEqual(service.output, "red")
        XCTAssertEqual(service.styledOutput.string, "red")
        let color = service.styledOutput.attributes(at: 0, effectiveRange: nil)[.foregroundColor] as? NSColor
        XCTAssertEqual(color?.redComponent ?? -1, 0.804, accuracy: 0.01)
    }

    func testTabSendsHorizontalTab() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 48, command: false, control: false, shift: false, characters: "\t"),
            .send(Data([0x09]))
        )
    }

    func testShiftTabSendsBacktabSequence() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 48, command: false, control: false, shift: true, characters: "\u{19}"),
            .send(Data("\u{1B}[Z".utf8))
        )
    }

    func testReturnSendsNewline() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 36, command: false, control: false, shift: false, characters: "\r"),
            .send(Data("\n".utf8))
        )
    }

    func testArrowsSendEscapeSequences() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 126, command: false, control: false, shift: false, characters: "\u{F700}"),
            .send(Data("\u{1B}[A".utf8))
        )
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 125, command: false, control: false, shift: false, characters: "\u{F701}"),
            .send(Data("\u{1B}[B".utf8))
        )
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 124, command: false, control: false, shift: false, characters: "\u{F702}"),
            .send(Data("\u{1B}[C".utf8))
        )
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 123, command: false, control: false, shift: false, characters: "\u{F703}"),
            .send(Data("\u{1B}[D".utf8))
        )
    }

    func testBackspaceSendsDel() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 51, command: false, control: false, shift: false, characters: "\u{7F}"),
            .send(Data([0x7F]))
        )
    }

    func testForwardDeleteSendsTildeSequence() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 117, command: false, control: false, shift: false, characters: "\u{F728}"),
            .send(Data("\u{1B}[3~".utf8))
        )
    }

    func testControlCForwardsTheControlByte() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 8, command: false, control: true, shift: false, characters: "\u{03}"),
            .send(Data([0x03]))
        )
    }

    func testCommandCPassesThroughToAppKit() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 8, command: true, control: false, shift: false, characters: "c"),
            .passThrough
        )
    }

    func testCommandVPastesToTheShell() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 9, command: true, control: false, shift: false, characters: "v"),
            .paste
        )
    }

    func testFunctionKeysAreIgnored() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 122, command: false, control: false, shift: false, characters: "\u{F704}"),
            .ignore
        )
    }

    func testPrintableTextPassesThroughVerbatim() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 0, command: false, control: false, shift: false, characters: "ğ"),
            .send(Data("ğ".utf8))
        )
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 2, command: false, control: false, shift: false, characters: "cd Des"),
            .send(Data("cd Des".utf8))
        )
    }

    func testEscapeSendsEscape() {
        XCTAssertEqual(
            TerminalKeyEncoder.action(keyCode: 53, command: false, control: false, shift: false, characters: "\u{1B}"),
            .send(Data([0x1B]))
        )
    }
}
