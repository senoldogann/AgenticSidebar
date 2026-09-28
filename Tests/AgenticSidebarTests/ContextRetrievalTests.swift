import Foundation
import XCTest

@testable import AgenticSidebar

/// Bağlam erişim eşliği: `@file` sözü, açık-dosya/seçim öz-bağlamı, sembol atlama.
///
/// Çıta: geçişsiz yol çözülmez, kök dışına okuma yapılmaz, eksik `rg`
/// uydurma sonuçla değil tipili hatayla döner.
final class ContextRetrievalTests: XCTestCase {
    private var workspace: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("context-retrieval-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workspace)
        try super.tearDownWithError()
    }

    private func write(_ relativePath: String, content: String) throws -> URL {
        let url =
            relativePath
            .split(separator: "/")
            .map(String.init)
            .reduce(workspace!) { url, component in
                url.appendingPathComponent(component)
            }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func resolver() -> FileMentionResolver {
        FileMentionResolver(workspaceRoot: workspace)
    }

    // MARK: - Ayrıştırıcı

    func testParserExtractsSingleMention() {
        let mentions = FileMentionParser.mentions(in: "bak @file Sources/App.swift lütfen")

        XCTAssertEqual(mentions.map(\.relativePath), ["Sources/App.swift"])
    }

    func testParserReadsQuotedPathWithSpaces() {
        let mentions = FileMentionParser.mentions(in: #"aç @file "Notlarım/Toplantı Notu.md" tamam"#)

        XCTAssertEqual(mentions.map(\.relativePath), ["Notlarım/Toplantı Notu.md"])
    }

    func testParserIgnoresPlainAtMentions() {
        XCTAssertTrue(FileMentionParser.mentions(in: "@dogan merhaba").isEmpty)
        XCTAssertTrue(FileMentionParser.mentions(in: "@filename değil").isEmpty)
        XCTAssertTrue(FileMentionParser.mentions(in: "yalnız @file").isEmpty)
    }

    func testParserTrimsTrailingPunctuationAndDedupes() {
        let mentions = FileMentionParser.mentions(in: "@file a.swift, sonra @file a.swift.")

        XCTAssertEqual(mentions.map(\.relativePath), ["a.swift"])
    }

    // MARK: - Çözümleyici

    func testResolverResolvesFileInsideWorkspace() throws {
        let url = try write("Sources/App.swift", content: "let x = 1\n")

        XCTAssertEqual(resolver().resolve(relativePath: "Sources/App.swift", fileManager: .default), url)
    }

    func testResolverRefusesTraversalAbsoluteMissingAndDirectory() throws {
        try write("Sources/App.swift", content: "let x = 1\n")
        let resolver = resolver()

        XCTAssertNil(resolver.resolve(relativePath: "../kaçış.swift", fileManager: .default))
        XCTAssertNil(resolver.resolve(relativePath: "/mutlak/yol.swift", fileManager: .default))
        XCTAssertNil(resolver.resolve(relativePath: "Sources/Yok.swift", fileManager: .default))
        XCTAssertNil(resolver.resolve(relativePath: "Sources", fileManager: .default))
        XCTAssertNil(resolver.resolve(relativePath: "   ", fileManager: .default))
    }

    func testResolverRefusesSymlinkEscape() throws {
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("dışarı-\(UUID().uuidString).txt")
        try "gizli".write(to: outside, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: workspace.appendingPathComponent("bağ.txt"),
            withDestinationURL: outside
        )

        XCTAssertNil(resolver().resolve(relativePath: "bağ.txt", fileManager: .default))
    }

    // MARK: - Tamamlama

    func testCompletionListsSingleLevelMatches() throws {
        try write("Sources/Foo.swift", content: "x")
        try write("Sources/Bar.swift", content: "x")
        try write("README.md", content: "x")

        XCTAssertEqual(
            resolver().complete(prefix: "Sources/", limit: 10, fileManager: .default),
            ["Sources/Bar.swift", "Sources/Foo.swift"]
        )
        XCTAssertEqual(resolver().complete(prefix: "READ", limit: 10, fileManager: .default), ["README.md"])
    }

    func testCompletionRefusesTraversalAndRespectsLimit() throws {
        try write("Sources/Foo.swift", content: "x")
        try write("Sources/Bar.swift", content: "x")

        XCTAssertTrue(resolver().complete(prefix: "../", limit: 10, fileManager: .default).isEmpty)
        XCTAssertTrue(resolver().complete(prefix: "/mutlak", limit: 10, fileManager: .default).isEmpty)
        XCTAssertEqual(resolver().complete(prefix: "Sources/", limit: 1, fileManager: .default).count, 1)
        XCTAssertTrue(resolver().complete(prefix: "Sources/", limit: 0, fileManager: .default).isEmpty)
    }

    // MARK: - Dosya okuma

    func testFileContextReaderTruncatesLongFile() throws {
        let url = try write("uzun.txt", content: String(repeating: "ab\n", count: 10_000))

        let excerpt = try XCTUnwrap(
            FileContextReader.read(url: url, relativePath: "uzun.txt", maximumBytes: 1_000_000, maximumCharacters: 100)
        )

        XCTAssertTrue(excerpt.truncated)
        XCTAssertTrue(excerpt.excerpt.hasSuffix("\n… [truncated]"))
    }

    func testFileContextReaderRefusesBinaryAndZeroBudget() throws {
        let url = workspace.appendingPathComponent("blob.bin")
        try Data([0xFF, 0xFE, 0x00, 0x01]).write(to: url)

        XCTAssertNil(FileContextReader.read(url: url, relativePath: "blob.bin", maximumBytes: 1_000, maximumCharacters: 1_000))
        let textURL = try write("a.txt", content: "x")
        XCTAssertNil(FileContextReader.read(url: textURL, relativePath: "a.txt", maximumBytes: 0, maximumCharacters: 10))
    }

    // MARK: - Öz-bağlam sağlayıcısı

    func testAutoContextCombinesAttachmentsMentionsAndClippedSelection() throws {
        let attached = try write("Sources/Ek.swift", content: "ek içerik\n")
        try write("Sources/Söz.swift", content: "söz içerik\n")
        let longSelection = String(repeating: "s", count: 5_000)

        let context = OpenFileContextProvider.context(
            draftText: "bak @file Sources/Söz.swift ve @file ../kaçış.swift",
            attachedURLs: [attached],
            workspaceRoot: workspace,
            selectedText: longSelection,
            maximumSelectionCharacters: 100,
            maximumFileBytes: 1_000_000,
            maximumFileCharacters: 100_000,
            fileManager: .default
        )

        XCTAssertEqual(context.workspaceRootPath, workspace.path)
        XCTAssertEqual(context.fileExcerpts.map(\.relativePath), ["Sources/Ek.swift", "Sources/Söz.swift"])
        XCTAssertTrue(context.selectionExcerpt?.hasSuffix("\n[…kırpıldı]") == true)
        let markdown = context.markdown()
        XCTAssertTrue(markdown.contains("**File:** `Sources/Söz.swift`"))
        XCTAssertTrue(markdown.contains("**Selection:**"))
    }

    func testAutoContextWithoutRootSkipsMentionsButKeepsSelection() throws {
        let attached = try write("Sources/Ek.swift", content: "ek\n")

        let context = OpenFileContextProvider.context(
            draftText: "@file Sources/Ek.swift",
            attachedURLs: [attached],
            workspaceRoot: nil,
            selectedText: "seçim",
            maximumSelectionCharacters: 100,
            maximumFileBytes: 1_000_000,
            maximumFileCharacters: 100_000,
            fileManager: .default
        )

        XCTAssertEqual(context.fileExcerpts.map(\.relativePath), ["Ek.swift"])
        XCTAssertEqual(context.selectionExcerpt, "seçim")
    }

    func testAutoContextDedupesAttachmentMentionOverlap() throws {
        let attached = try write("Sources/Aynı.swift", content: "aynı\n")

        let context = OpenFileContextProvider.context(
            draftText: "@file Sources/Aynı.swift",
            attachedURLs: [attached],
            workspaceRoot: workspace,
            selectedText: nil,
            maximumSelectionCharacters: 100,
            maximumFileBytes: 1_000_000,
            maximumFileCharacters: 100_000,
            fileManager: .default
        )

        XCTAssertEqual(context.fileExcerpts.count, 1)
        XCTAssertTrue(context.markdown().contains("Sources/Aynı.swift"))
    }

    // MARK: - Sembol dizini

    func testSymbolPatternEscapesQuery() {
        XCTAssertEqual(
            SymbolJumpIndex.symbolPattern(for: "C++"),
            "(?:func|class|struct|enum|protocol|typealias|let|var)\\s+C\\+\\+\\b"
        )
        XCTAssertEqual(
            SymbolJumpIndex.symbolPattern(for: "App.View"),
            "(?:func|class|struct|enum|protocol|typealias|let|var)\\s+App\\.View\\b"
        )
    }

    func testParseVimgrepLineKeepsColonsInText() {
        let match = SymbolJumpIndex.parseVimgrepLine("Sources/App.swift:12:8:    func aç(url: URL): Bool", workspaceRoot: workspace)

        XCTAssertEqual(match?.relativePath, "Sources/App.swift")
        XCTAssertEqual(match?.line, 12)
        XCTAssertEqual(match?.column, 8)
        XCTAssertTrue(match?.text.contains("url: URL") == true)
    }

    func testParseVimgrepLineRefusesBrokenAndEscapingLines() {
        XCTAssertNil(SymbolJumpIndex.parseVimgrepLine("bozuk satır", workspaceRoot: workspace))
        XCTAssertNil(SymbolJumpIndex.parseVimgrepLine("a.swift:sıfır:8:x", workspaceRoot: workspace))
        XCTAssertNil(SymbolJumpIndex.parseVimgrepLine("/mutlak/a.swift:1:1:x", workspaceRoot: workspace))
        XCTAssertNil(SymbolJumpIndex.parseVimgrepLine("../kaçış.swift:1:1:x", workspaceRoot: workspace))
    }

    func testRgLookupPrefersFixedCandidatesThenPathEnvironment() throws {
        let bin = workspace.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let rg = bin.appendingPathComponent("rg")
        try "#!/bin/sh\n".write(to: rg, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rg.path)

        // Sabit aday tutarsa `PATH`e bakılmaz.
        XCTAssertEqual(
            SymbolJumpIndex.rgExecutableURL(
                fileManager: .default,
                pathEnvironment: "",
                fixedCandidates: [rg.path]
            )?.path,
            rg.path
        )
        // Sabit tutmazsa `PATH` taraması devreye girer.
        XCTAssertEqual(
            SymbolJumpIndex.rgExecutableURL(
                fileManager: .default,
                pathEnvironment: bin.path,
                fixedCandidates: ["/yok/dizin/rg"]
            )?.path,
            rg.path
        )
        // Hiçbir yerde yoksa sonuç yoktur.
        XCTAssertNil(
            SymbolJumpIndex.rgExecutableURL(
                fileManager: .default,
                pathEnvironment: "",
                fixedCandidates: ["/yok/dizin/rg"]
            )
        )
    }

    // MARK: - Sembol araması (taklit koşucu)

    private final class StubCommandRunner: SymbolCommandRunning, @unchecked Sendable {
        let result: GitCommandResult
        private(set) var recordedArguments: [String] = []

        init(result: GitCommandResult) {
            self.result = result
        }

        func run(executable: String, arguments: [String], directory: URL, timeout: TimeInterval) throws -> GitCommandResult {
            recordedArguments = arguments
            return result
        }
    }

    private func searchService(output: String, exitCode: Int32) -> (SymbolJumpService, StubCommandRunner) {
        let stub = StubCommandRunner(
            result: GitCommandResult(
                exitCode: exitCode, standardOutput: output, standardError: exitCode == 0 ? "" : "hata", outputWasTruncated: false)
        )
        let service = SymbolJumpService(
            workspaceRoot: workspace,
            rgExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/rg"),
            commandRunner: stub,
            timeout: 10
        )
        return (service, stub)
    }

    func testSymbolSearchReturnsMatchesCappedByLimit() throws {
        let output = "A.swift:1:6:func bir(): x\nA.swift:9:7:struct iki: y\nB.swift:3:6:func üç(): z\n"
        let (service, stub) = searchService(output: output, exitCode: 0)

        let matches = try service.search(query: "bir", limit: 2)

        XCTAssertEqual(matches.count, 2)
        XCTAssertEqual(matches.first?.relativePath, "A.swift")
        XCTAssertTrue(stub.recordedArguments.contains("--vimgrep"))
        XCTAssertTrue(stub.recordedArguments.contains("!.git"))
    }

    func testSymbolSearchNoMatchReturnsEmpty() throws {
        let (service, _) = searchService(output: "", exitCode: 1)

        XCTAssertTrue(try service.search(query: "yok", limit: 10).isEmpty)
    }

    func testSymbolSearchFailureCarriesExitCodeAndStderr() {
        let (service, _) = searchService(output: "", exitCode: 2)

        XCTAssertThrowsError(try service.search(query: "x", limit: 10)) { error in
            XCTAssertEqual(error as? SymbolJumpError, .searchFailed(exitCode: 2, stderr: "hata"))
        }
    }

    func testSymbolSearchRefusesEmptyQueryAndBadLimit() {
        let (service, _) = searchService(output: "", exitCode: 0)

        XCTAssertThrowsError(try service.search(query: "   ", limit: 10)) { error in
            XCTAssertEqual(error as? SymbolJumpError, .emptyQuery)
        }
        XCTAssertThrowsError(try service.search(query: "x", limit: 0)) { error in
            XCTAssertEqual(error as? SymbolJumpError, .invalidLimit(limit: 0))
        }
        XCTAssertThrowsError(try service.search(query: "a\nb", limit: 10)) { error in
            guard case .invalidQuery = error as? SymbolJumpError else {
                return XCTFail("invalidQuery beklenir")
            }
        }
    }
}
