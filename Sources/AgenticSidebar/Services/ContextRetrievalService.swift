import Foundation

// MARK: - @file sözü ayrıştırma

/// Bestecideki `@file yol` sözünün ayrışmış hâli.
struct FileMention: Sendable, Equatable {
    /// Eşleşen ham aralık (`@file "ad Soyad.swift"` gibi).
    let rawText: String
    /// Tırnakları soyulmuş, çalışma alanına göreli yazım.
    let relativePath: String
}

/// Besteci metnindeki `@file` sözlerini sıralı ve yinelenensiz çıkarır.
///
/// `@dogan` gibi düz anmalar yok sayılır: yalnız bağımsız `@file` jetonu ve
/// ardından gelen yol okunur. Çözümleme burada yapılmaz; kök denetimi
/// `FileMentionResolver` içindedir.
enum FileMentionParser {
    /// Tek başına `@file` sayılması için önünde durabilecek karakterler.
    /// Boşlukların yanında parantez ve liste ayraçları da sınırdır.
    static func isBoundary(_ character: Character) -> Bool {
        character.isWhitespace || "([{,:;".contains(character)
    }

    /// Yolun bittiği yer: boşluk ya da kapatma ayracı. Tırnak da bitirir,
    /// çünkü çıplak yazımda tırnak yolun parçası değildir.
    static func isBareTerminator(_ character: Character) -> Bool {
        character.isWhitespace || ",;)]\"'`".contains(character)
    }

    /// Cümle sonu noktalaması (`foo.swift,` gibi) yoldan kırpılır.
    /// `+`, `-`, `_`, `/` korunur (`C++`, `kebab-case` bozulmaz).
    static func trimmedBareToken(_ token: String) -> String {
        var result = token
        while let last = result.last, ",;:)].!?".contains(last) {
            result.removeLast()
        }
        return result
    }

    static func mentions(in text: String) -> [FileMention] {
        var found: [FileMention] = []
        var seen: Set<String> = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let tokenRange = text.range(of: "@file", range: cursor..<text.endIndex) else {
                break
            }
            let beforeOK =
                tokenRange.lowerBound == text.startIndex
                || isBoundary(text[text.index(before: tokenRange.lowerBound)])
            let afterOK =
                tokenRange.upperBound < text.endIndex
                && text[tokenRange.upperBound].isWhitespace
            guard beforeOK, afterOK else {
                cursor = tokenRange.upperBound
                continue
            }
            var pathCursor = tokenRange.upperBound
            while pathCursor < text.endIndex, text[pathCursor].isWhitespace {
                pathCursor = text.index(after: pathCursor)
            }
            guard pathCursor < text.endIndex else {
                break
            }
            guard let mention = readMention(from: text, pathCursor: pathCursor) else {
                cursor = tokenRange.upperBound
                continue
            }
            cursor = mention.endIndex
            guard !mention.relativePath.isEmpty, seen.insert(mention.relativePath).inserted else {
                continue
            }
            found.append(FileMention(rawText: String(text[tokenRange.lowerBound..<mention.endIndex]), relativePath: mention.relativePath))
        }
        return found
    }

    /// Tırnaklı ya da çıplak yolu okur; yol yoksa ya da tırnak kapanmamışsa `nil`.
    private static func readMention(
        from text: String,
        pathCursor: String.Index
    ) -> (relativePath: String, endIndex: String.Index)? {
        let opener = text[pathCursor]
        if opener == "\"" || opener == "'" || opener == "`" {
            guard let closer = text[pathCursor...].dropFirst().firstIndex(of: opener) else {
                return nil
            }
            let path = String(text[text.index(after: pathCursor)..<closer])
            return (path, text.index(after: closer))
        }
        var end = pathCursor
        while end < text.endIndex, !isBareTerminator(text[end]) {
            end = text.index(after: end)
        }
        let path = trimmedBareToken(String(text[pathCursor..<end]))
        guard !path.isEmpty else {
            return nil
        }
        return (path, end)
    }
}

// MARK: - @file çözümleyici

/// `@file` yolunu çalışma alanı köküne karşı çözer.
///
/// Güvenlik `SkillInstaller.resolvedURL` deseniyle aynıdır: mutlak yol ve
/// `..` sözlüksel reddedilir, sembolik bağ kaçışı
/// `WorkspacePathContainment` adım adım denetimiyle yakalanır. Dizinler
/// bağlam okuması için çözülmez (`nil` döner); tamamlama ayrı yoldur.
struct FileMentionResolver: Sendable {
    let workspaceRoot: URL

    /// Göreli yolu kök içindeki var olan bir dosyaya çevirir, yoksa `nil`.
    func resolve(relativePath: String, fileManager: FileManager) -> URL? {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        guard !WorkspacePathContainment.relativePath(trimmed, escapesWorkspace: workspaceRoot) else {
            return nil
        }
        let candidate =
            trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .reduce(workspaceRoot) { url, component in
                url.appendingPathComponent(component)
            }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    /// Önekle eşleşen kök-içi yolları tek düzey listeler.
    ///
    /// Önek kendisi kaçış içeriyorsa (`/mutlak`, `../`) sonuç boştur.
    /// Dizinler sondaki `/` ile döner; sonuç sıralı ve `limit` ile sınırlıdır.
    func complete(prefix: String, limit: Int, fileManager: FileManager) -> [String] {
        guard limit > 0 else {
            return []
        }
        let trimmed = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !WorkspacePathContainment.relativePath(trimmed, escapesWorkspace: workspaceRoot) else {
            return []
        }
        let directoryPart: String
        let needle: String
        if let slash = trimmed.lastIndex(of: "/") {
            directoryPart = String(trimmed[..<slash])
            needle = String(trimmed[trimmed.index(after: slash)...])
        } else {
            directoryPart = ""
            needle = trimmed
        }
        let base: URL
        if directoryPart.isEmpty {
            base = workspaceRoot
        } else {
            base =
                directoryPart
                .split(separator: "/", omittingEmptySubsequences: true)
                .map(String.init)
                .reduce(workspaceRoot) { url, component in
                    url.appendingPathComponent(component)
                }
        }
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: base,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            )
        else {
            return []
        }
        let loweredNeedle = needle.lowercased()
        var matches: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.lowercased().hasPrefix(loweredNeedle) else {
                continue
            }
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let relative = directoryPart.isEmpty ? name : directoryPart + "/" + name
            matches.append(isDirectory ? relative + "/" : relative)
        }
        matches.sort { $0.lowercased() < $1.lowercased() }
        return Array(matches.prefix(limit))
    }
}

// MARK: - Sınırlı dosya okuma

/// Bağlama taşınan dosya parçası.
struct ResolvedFileContext: Sendable, Equatable {
    /// Kök-göreli görünen yol (`Sources/App.swift` gibi).
    let relativePath: String
    let excerpt: String
    let truncated: Bool
}

/// Dosyanın sınırlı ön ekini okur.
///
/// `FileInspectorPanelView.readTextPrefix` ile aynı sınır fikri: bayt bütçesi
/// aşılmaz, metin olmayan dosya `nil` döner. Kırpma işareti dosya önizlemesi
/// geleneğini (`… [truncated]`) izler.
enum FileContextReader {
    static func read(url: URL, relativePath: String, maximumBytes: Int, maximumCharacters: Int) -> ResolvedFileContext? {
        guard maximumBytes > 0, maximumCharacters > 0 else {
            return nil
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard var data = try? handle.read(upToCount: maximumBytes), !data.isEmpty else {
            return nil
        }
        var text: String?
        for _ in 0..<4 {
            if let decoded = String(data: data, encoding: .utf8) {
                text = decoded
                break
            }
            guard !data.isEmpty else {
                break
            }
            data = data.dropLast()
        }
        guard let text else {
            return nil
        }
        if text.count > maximumCharacters {
            return ResolvedFileContext(
                relativePath: relativePath,
                excerpt: String(text.prefix(maximumCharacters)) + "\n… [truncated]",
                truncated: true
            )
        }
        return ResolvedFileContext(relativePath: relativePath, excerpt: text, truncated: false)
    }
}

// MARK: - Açık dosya / seçim öz-bağlamı

/// Bestecinin o anki hâlinden derlenen öz-bağlam.
///
/// Kaynaklar yalnızca mevcut yapılardır: taslak metni ve ekleri
/// `ComposerDraftMemory` içindeki `ComposerDraft` alanlarından, seçim
/// `ContextSnap` seçili-metin yolundan, kök oturumun
/// `workingDirectoryPath` değerinden gelir. Paralel depo tutulmaz;
/// `MainWindowController` pencere yaşam döngüsünden başka editör durumu
/// taşımadığı için doğruluk kaynağı besteci belleğidir.
struct EditorAutoContext: Sendable, Equatable {
    let workspaceRootPath: String?
    /// Ekler önce (kullanıcının sırası), sonra `@file` sözleri (metin sırası).
    let fileExcerpts: [ResolvedFileContext]
    let selectionExcerpt: String?

    /// İsteme enjekte edilecek markdown; boş bağlam boş metindir.
    func markdown() -> String {
        var lines: [String] = []
        for excerpt in fileExcerpts {
            let fence = ContextSnap.codeFence(for: excerpt.excerpt)
            lines.append("**File:** `\(excerpt.relativePath)`\n\(fence)\n\(excerpt.excerpt)\n\(fence)")
        }
        if let selectionExcerpt {
            let fence = ContextSnap.codeFence(for: selectionExcerpt)
            lines.append("**Selection:**\n\(fence)\n\(selectionExcerpt)\n\(fence)")
        }
        return lines.joined(separator: "\n")
    }
}

enum OpenFileContextProvider {
    /// Mevcut besteci alanlarından öz-bağlamı derler.
    ///
    /// - Parameters:
    ///   - draftText: Besticide yazılmakta olan metin (`@file` sözleri buradan çıkar).
    ///   - attachedURLs: Besticideki eklerin mutlak yolları (kullanıcının açık seçimi olduğu için kök dışındakiler de okunur).
    ///   - workspaceRoot: Oturumun çalışma dizini; `nil` ise söz çözümlemesi atlanır.
    ///   - selectedText: Mevcut seçim deposundaki seçili metin.
    static func context(
        draftText: String,
        attachedURLs: [URL],
        workspaceRoot: URL?,
        selectedText: String?,
        maximumSelectionCharacters: Int,
        maximumFileBytes: Int,
        maximumFileCharacters: Int,
        fileManager: FileManager
    ) -> EditorAutoContext {
        var excerpts: [ResolvedFileContext] = []
        var seen: Set<String> = []
        for url in attachedURLs {
            let relativePath = displayPath(for: url, workspaceRoot: workspaceRoot)
            guard seen.insert(relativePath).inserted else {
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                continue
            }
            // Okunamayan ek sessizce düşer (`AttachmentPaths` geleneği):
            // bozuk bir yol ajana gönderilmez.
            guard
                let excerpt = FileContextReader.read(
                    url: url,
                    relativePath: relativePath,
                    maximumBytes: maximumFileBytes,
                    maximumCharacters: maximumFileCharacters
                )
            else {
                continue
            }
            excerpts.append(excerpt)
        }
        if let workspaceRoot {
            let resolver = FileMentionResolver(workspaceRoot: workspaceRoot)
            for mention in FileMentionParser.mentions(in: draftText) {
                guard seen.insert(mention.relativePath).inserted else {
                    continue
                }
                guard let url = resolver.resolve(relativePath: mention.relativePath, fileManager: fileManager) else {
                    continue
                }
                guard
                    let excerpt = FileContextReader.read(
                        url: url,
                        relativePath: mention.relativePath,
                        maximumBytes: maximumFileBytes,
                        maximumCharacters: maximumFileCharacters
                    )
                else {
                    continue
                }
                excerpts.append(excerpt)
            }
        }
        return EditorAutoContext(
            workspaceRootPath: workspaceRoot?.path,
            fileExcerpts: excerpts,
            selectionExcerpt: clippedSelection(selectedText, maximumCharacters: maximumSelectionCharacters)
        )
    }

    /// Mutlak ek yolunun görünen adı: kök içindeyse göreli, dışındaysa dosya adı.
    /// Kök denetimi `GoalSafety.isPathInsideSandbox` ile yapılır (bağ çözer).
    static func displayPath(for url: URL, workspaceRoot: URL?) -> String {
        guard let workspaceRoot,
            GoalSafety.isPathInsideSandbox(path: url.path, sandboxRoot: workspaceRoot.path)
        else {
            return url.lastPathComponent
        }
        let rootPath = workspaceRoot.standardized.path
        let candidate = url.standardized.path
        guard candidate.hasPrefix(rootPath + "/") else {
            return url.lastPathComponent
        }
        return String(candidate.dropFirst(rootPath.count + 1))
    }

    /// Seçim kırpması `ContextSnap` geleneğini izler (`[…kırpıldı]`).
    static func clippedSelection(_ selectedText: String?, maximumCharacters: Int) -> String? {
        guard maximumCharacters > 0 else {
            return nil
        }
        guard let trimmed = selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count > maximumCharacters {
            return String(trimmed.prefix(maximumCharacters)) + "\n[…kırpıldı]"
        }
        return trimmed
    }
}

// MARK: - Sembol atlama (rg dizini)

/// Sembol eşleşmesi: `rg --vimgrep` satırının ayrışmış hâli.
struct SymbolMatch: Sendable, Equatable {
    /// Kök-göreli yol (`Sources/App.swift` gibi).
    let relativePath: String
    /// 1-tabanlı satır ve sütun.
    let line: Int
    let column: Int
    /// Eşleşen satırın ham metni.
    let text: String
}

/// Sembol atlama hataları; bilinmeyen hiçbir zaman uydurulmaz.
enum SymbolJumpError: LocalizedError, Equatable, Sendable {
    case emptyQuery
    case invalidQuery(query: String)
    case invalidLimit(limit: Int)
    case toolUnavailable(reason: String)
    case timedOut(executable: String, timeout: TimeInterval)
    case searchFailed(exitCode: Int32, stderr: String)

    var errorDescription: String? {
        switch self {
        case .emptyQuery:
            return "SYMBOL_JUMP_EMPTY_QUERY: symbol query is empty"
        case .invalidQuery(let query):
            return "SYMBOL_JUMP_INVALID_QUERY: symbol query is refused: \(query)"
        case .invalidLimit(let limit):
            return "SYMBOL_JUMP_INVALID_LIMIT: result limit must be positive: \(limit)"
        case .toolUnavailable(let reason):
            return "SYMBOL_JUMP_TOOL_UNAVAILABLE: rg is not available: \(reason)"
        case .timedOut(let executable, let timeout):
            return "SYMBOL_JUMP_TIMEOUT: \(executable) did not finish within \(timeout)s"
        case .searchFailed(let exitCode, let stderr):
            return "SYMBOL_JUMP_FAILED: rg exited \(exitCode): \(stderr)"
        }
    }
}

/// `GitCommandRunner` için dar port; canlıda gerçek koşucu, testte taklit.
/// Yeni koşucu yazılmaz, mevcut sabit-argv altyapısı (`VerificationRunner` ve
/// `GitWorkspaceManager` ile aynı) yeniden kullanılır: kabuk yok, süre ve
/// bayt bütçesi zorunludur.
protocol SymbolCommandRunning: Sendable {
    func run(executable: String, arguments: [String], directory: URL, timeout: TimeInterval) throws -> GitCommandResult
}

extension GitCommandRunner: SymbolCommandRunning {}

/// Tanım arama kalıpları ve `rg` konumu için saf yardımcılar.
enum SymbolJumpIndex {
    /// Sorgudaki en uzun sembol adı; en fazla 200 karakter.
    nonisolated static let maximumQueryCharacters = 200

    /// Üretim `rg` adayları: sabitler önce (`VerificationToolchain` sırası),
    /// bulunamazsa `PATH` taraması. Aday listesi enjekte edilir ki test
    /// makinedeki gerçek kuruluma bağlanmasın.

    /// Tanım kalıbı: `func|class|struct|enum|protocol|typealias|let|var`
    /// ardından ad. Sorgu kaçışlıdır, desene olduğu gibi gömülmez.
    static func symbolPattern(for query: String) -> String {
        "(?:func|class|struct|enum|protocol|typealias|let|var)\\s+" + escaped(query) + "\\b"
    }

    /// Desen üst-dizisini kaçırır (`C++` → `C\+\+`).
    static func escaped(_ query: String) -> String {
        var result = ""
        result.reserveCapacity(query.count)
        for character in query {
            if "\\^$.|?*+()[]{}".contains(character) {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }

    /// `yol:satır:sütun:metin` satırını ayrıştırır; metindeki `:` korunur.
    /// Kök dışına taşan ya da bozuk satır `nil` döner.
    static func parseVimgrepLine(_ line: String, workspaceRoot: URL) -> SymbolMatch? {
        guard let firstColon = line.firstIndex(of: ":") else {
            return nil
        }
        let pathPart = String(line[..<firstColon])
        let afterFirst = line[line.index(after: firstColon)...]
        guard let secondColon = afterFirst.firstIndex(of: ":") else {
            return nil
        }
        let linePart = String(afterFirst[..<secondColon])
        let afterSecond = afterFirst[afterFirst.index(after: secondColon)...]
        guard let thirdColon = afterSecond.firstIndex(of: ":") else {
            return nil
        }
        let columnPart = String(afterSecond[..<thirdColon])
        let textPart = String(afterSecond[afterSecond.index(after: thirdColon)...])
        guard let lineNumber = Int(linePart), let columnNumber = Int(columnPart),
            lineNumber >= 1, columnNumber >= 1,
            !pathPart.isEmpty, !pathPart.hasPrefix("/"),
            !WorkspacePathContainment.relativePath(pathPart, escapesWorkspace: workspaceRoot)
        else {
            return nil
        }
        return SymbolMatch(relativePath: pathPart, line: lineNumber, column: columnNumber, text: textPart)
    }

    /// `rg` konumunu sabit adaylar ve `PATH` taramasıyla bulur.
    /// Sıra `VerificationToolchain` ile aynıdır (sabitler önce, kabuk yok);
    /// `pathEnvironment` ve `fixedCandidates` enjekte edilir ki test ne
    /// kabuğa ne de makinedeki gerçek kuruluma dokunsun.
    static func rgExecutableURL(fileManager: FileManager, pathEnvironment: String, fixedCandidates: [String]) -> URL? {
        if let fixed = fixedCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: fixed)
        }
        for directory in pathEnvironment.split(separator: ":").map(String.init).filter({ !$0.isEmpty }) {
            let candidate = (directory as NSString).appendingPathComponent("rg")
            if fileManager.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}

/// LSP yokken sembol tanımları için `rg` tabanlı dizin araması.
struct SymbolJumpService: Sendable {
    let workspaceRoot: URL
    let rgExecutableURL: URL
    let commandRunner: any SymbolCommandRunning
    let timeout: TimeInterval

    /// Üretim kablolaması: `rg` bulunamazsa fırlatır, ikame koşucu uydurulmaz.
    /// (`VerificationResolver` geleneği: eksik araç reddedilir.)
    static func live(
        workspaceRoot: URL,
        fileManager: FileManager,
        pathEnvironment: String,
        timeout: TimeInterval,
        maximumOutputBytes: Int
    ) throws -> SymbolJumpService {
        let fixedCandidates = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg", "/usr/bin/rg"]
        guard
            let rgURL = SymbolJumpIndex.rgExecutableURL(
                fileManager: fileManager,
                pathEnvironment: pathEnvironment,
                fixedCandidates: fixedCandidates
            )
        else {
            throw SymbolJumpError.toolUnavailable(reason: "rg executable was not found in fixed locations or PATH")
        }
        let runner = GitCommandRunner(
            executableDirectory: rgURL.deletingLastPathComponent(),
            maxOutputBytes: maximumOutputBytes
        )
        return SymbolJumpService(workspaceRoot: workspaceRoot, rgExecutableURL: rgURL, commandRunner: runner, timeout: timeout)
    }

    /// Tanım eşleşmelerini kök-göreli ve `limit` ile sınırlı döner.
    /// `rg` çıkışı 1 ise eşleşme yoktur (`[]`); başka sıfır-dışı çıkış
    /// `searchFailed` olur, stderr ilk 500 karakteriyle taşınır.
    func search(query: String, limit: Int) throws -> [SymbolMatch] {
        guard limit > 0 else {
            throw SymbolJumpError.invalidLimit(limit: limit)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SymbolJumpError.emptyQuery
        }
        guard trimmed.count <= SymbolJumpIndex.maximumQueryCharacters,
            !trimmed.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" })
        else {
            throw SymbolJumpError.invalidQuery(query: String(trimmed.prefix(100)))
        }
        let pattern = SymbolJumpIndex.symbolPattern(for: trimmed)
        let arguments = ["--vimgrep", "--no-heading", "--smart-case", "--glob", "!.git", "-e", pattern, "."]
        let result: GitCommandResult
        do {
            result = try commandRunner.run(executable: "rg", arguments: arguments, directory: workspaceRoot, timeout: timeout)
        } catch let guardError as WorkspaceGuardError {
            switch guardError {
            case .gitTimedOut(let executable, _, let timedOut):
                throw SymbolJumpError.timedOut(executable: executable, timeout: timedOut)
            default:
                throw SymbolJumpError.searchFailed(exitCode: -1, stderr: "\(guardError)")
            }
        } catch let runnerError as GitCommandRunnerError {
            throw SymbolJumpError.toolUnavailable(reason: runnerError.localizedDescription)
        }
        if result.exitCode == 1 {
            return []
        }
        guard result.exitCode == 0 else {
            throw SymbolJumpError.searchFailed(exitCode: result.exitCode, stderr: String(result.standardError.prefix(500)))
        }
        let matches = result.standardOutput
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { SymbolJumpIndex.parseVimgrepLine(String($0), workspaceRoot: workspaceRoot) }
        return Array(matches.prefix(limit))
    }
}
