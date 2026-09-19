import Foundation

/// Hedef döngüsünün güvenlik barikatı: yıkıcı komutlar, sandbox-dışı yollar ve
/// korumalı dallara yazım daha çalıştırılmadan reddedilir. Saf fonksiyondur.
enum GoalSafety {
    /// Yıkıcı komutları yakalar: kök silme, disk biçimlendirme, ham yazım,
    /// fork-bomb, sert sıfırlama ve toplu geri alma, zorla gönderim ve zorla
    /// dal işlemi, korumalı dala yazım, kapatma komutları.
    /// Göreli alt yol temizlikleri (`rm -rf .build` gibi) serbesttir; onların
    /// sınırı `isPathInsideSandbox` ile çizilir.
    static func isForbiddenCommand(_ command: String) -> Bool {
        let lowered = command.lowercased()
        // Boşluk varyantlı fork-bomb (`:(){ :|:& };:`): boşluklar atılınca
        // kalıp aranır, yoksa araya boşluk koyarak atlatılırdı.
        if lowered.filter({ !$0.isWhitespace }).contains(":(){:|:&};") {
            return true
        }
        let tokens = tokenize(lowered)
        if tokens.isEmpty {
            return false
        }
        // Komut adı son bileşenden okunur: `/bin/rm` mutlak yolu da `rm`dir,
        // yoksa yola gömerek barikat atlatılırdı.
        let names = tokens.map(commandName)
        if names.contains("dd") {
            return true
        }
        if names.contains(where: { $0 == "mkfs" || $0.hasPrefix("mkfs.") || $0.hasPrefix("newfs") }) {
            return true
        }
        if names.contains("diskutil")
            && tokens.contains(where: { ["erasedisk", "erasevolume", "zerodisk", "randomdisk", "secureerase"].contains($0) })
        {
            return true
        }
        if names.contains(where: { ["shutdown", "reboot", "halt", "poweroff"].contains($0) }) {
            return true
        }
        // Boruya gömülü kabuk (`curl … | sh`, `wget … | bash`): taşınan metin
        // denetlenmeden yorumlanır, üstteki ad bazlı barikatın altından
        // geçerdi. Hedef komutlar sabittir (`swift build`/`swift test`),
        // kabuk yorumlayıcısının hedef döngüsünde işi yoktur.
        if names.contains(where: { ["sh", "bash", "zsh", "dash", "fish", "osascript"].contains($0) }) {
            return true
        }
        if isDestructiveRm(tokens) {
            return true
        }
        if names.contains("git") && isDestructiveGit(tokens, rawTokens: tokenize(command)) {
            return true
        }
        if (names.contains("find") || names.contains("gfind")) && isDestructiveFind(tokens) {
            return true
        }
        return false
    }

    /// Yol sandbox kökünün içindeyse `true` döner. `..` kaçışları ve
    /// öneki-kardeş yollar (`/proje2`, kök `/proje` iken) dışarıdadır.
    /// Sembolik bağlar çözülür: kök-içi görünüp dışarıyı gösteren bağ
    /// (`sandbox/link` → `/etc`) içeride sayılmazdı.
    static func isPathInsideSandbox(path: String, sandboxRoot: String) -> Bool {
        let root = URL(fileURLWithPath: sandboxRoot).standardized.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: path).standardized.resolvingSymlinksInPath().path
        if candidate.isEmpty || root.isEmpty {
            return false
        }
        return candidate == root || candidate.hasPrefix(root + "/")
    }

    /// Korumalı dallara (ana dal gibi) yazım yasaktır. `refs/heads/` öneki ve
    /// boşluklar kırpılır: aynı dalın uzun yazımı korumayı delmesin.
    static func mayWriteToBranch(_ branch: String, protectedBranches: [String]) -> Bool {
        var normalized = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.hasPrefix("refs/heads/") {
            normalized = String(normalized.dropFirst("refs/heads/".count))
        }
        return !protectedBranches.contains(normalized)
    }

    // MARK: - Özel denetimler

    /// Komutu ayraçlardan bölüp jeton listesi çıkarır. Kabuk sarmaları
    /// (`$(...)`, ters tırnak, parantez, süslü açılım) soyulur, boşluk
    /// karakterlerinin tamamı ayraçtır (sekme/satırsonuyla atlatma olmaz),
    /// `$HOME` gibi değişkenler korunur.
    private static func tokenize(_ command: String) -> [String] {
        var normalized = command
        // Önce değişken parantezi çözülür (`${HOME}` → `$HOME`): süslü ayraç
        // bölmesi `${...}` içini parçalayıp hedefi gizlerdi.
        normalized = normalized.replacingOccurrences(of: "${", with: "$")
        normalized = normalized.replacingOccurrences(of: "}", with: "")
        for separator in [";", "|", "&", "(", ")", "`", "{", "}", ","] {
            normalized = normalized.replacingOccurrences(of: separator, with: " ")
        }
        return normalized.split(whereSeparator: { $0.isWhitespace }).map { normalizeToken(String($0)) }
    }

    /// Jetonun kabuk sarmasını soyar, değişken öneki (`$`) korunur. Tırnak ve
    /// kaçışlar atılır (`rm -rf "/"` çıplak `/` ile aynıdır), `${HOME}`
    /// parantezi çözülür.
    private static func normalizeToken(_ token: String) -> String {
        var result =
            token
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "${", with: "$")
            .replacingOccurrences(of: "}", with: "")
        while result.hasPrefix("$(") {
            result.removeFirst(2)
        }
        while result.hasPrefix("(") {
            result.removeFirst()
        }
        while result.hasSuffix(")") {
            result.removeLast()
        }
        return result
    }

    /// Jetonun komut adı: yol gömülüyse son bileşen (`/bin/rm` → `rm`).
    private static func commandName(_ token: String) -> String {
        URL(fileURLWithPath: token).lastPathComponent
    }

    /// Kökü hedefleyen `rm -r` çeşitlerini yakalar. Yinelemeli bayrak bitişik
    /// yazılabilir (`-rfv`), hedef tırnaklı/kaçışlı olabilir (`"/"`,
    /// `${HOME}`) ve nokta parçaları sözlüksel çözülür (`/.`, `/tmp/..`,
    /// `..` hepsi kökü/ebeveyni vurur). Ev-dizini altındaki her yol önekten
    /// yakalanır (`~/belgeler`, `$HOME/indirilenler` dahil); `~kullanıcı`
    /// yazımı da ev dizinidir.
    private static func isDestructiveRm(_ tokens: [String]) -> Bool {
        guard let rmIndex = tokens.firstIndex(where: { commandName($0) == "rm" }) else {
            return false
        }
        let after = tokens.dropFirst(rmIndex + 1)
        guard after.contains(where: isRecursiveFlag) else {
            return false
        }
        let targets = after.filter { !$0.hasPrefix("-") }
        if targets.isEmpty {
            return true
        }
        return targets.contains(where: isDestructiveRmTarget)
    }

    /// Yinelemeli bayrak: `--recursive` ya da içinde `r` geçen bitişik kısa
    /// bayrak (`-r`, `-rf`, `-rfv`). Bitişik yazım atlatma yoluydu.
    private static func isRecursiveFlag(_ token: String) -> Bool {
        if token == "--recursive" {
            return true
        }
        guard token.hasPrefix("-"), !token.hasPrefix("--"), token.count > 1 else {
            return false
        }
        return token.dropFirst().contains("r")
    }

    /// Hedef jetonu normalize edip kök kümesine ve ev-dizini öneklerine bakar.
    private static func isDestructiveRmTarget(_ target: String) -> Bool {
        let normalized = normalizeRmTarget(target)
        let roots = Set(["/", "/*", "~", "~/*", "$home", "$home/*", ".", "*"])
        if roots.contains(normalized) {
            return true
        }
        // Ev-dizini altındaki her şey: `~/x`, `~/*`, `$home/x` ve `~kullanıcı`.
        if normalized.hasPrefix("~/") || normalized.hasPrefix("$home/") || normalized.hasPrefix("~") {
            return true
        }
        // Ebeveyne çıkış: `..`, `../x`.
        return normalized == ".." || normalized.hasPrefix("../")
    }

    /// Sondaki `/` kırpılır, baştaki `./` atılır, nokta parçaları dosya
    /// sistemine bakmadan çözülür. Boş kalan (`./.`) bulunulan dizindir.
    private static func normalizeRmTarget(_ target: String) -> String {
        var result = target
        while result.hasSuffix("/") && result.count > 1 {
            result.removeLast()
        }
        while result.hasPrefix("./") {
            result.removeFirst(2)
        }
        let resolved = resolveDotSegments(result)
        return resolved.isEmpty ? "." : resolved
    }

    /// `.` düşer, `..` yığını patlatır; mutlak yolda kökün üstü köktür,
    /// göreli yolda başa taşan `..` korunur.
    private static func resolveDotSegments(_ path: String) -> String {
        let isAbsolute = path.hasPrefix("/")
        var stack: [String] = []
        for part in path.split(separator: "/") {
            if part == "." || part.isEmpty {
                continue
            }
            if part == ".." {
                if let last = stack.last, last != ".." {
                    stack.removeLast()
                } else if !isAbsolute {
                    stack.append("..")
                }
                continue
            }
            stack.append(String(part))
        }
        let joined = stack.joined(separator: "/")
        return isAbsolute ? "/" + joined : joined
    }

    /// Sert sıfırlama ve toplu geri alma, zorla gönderim (`--force` ve bitişik
    /// `-f`), refspec hileleri (`+dal`, `kaynak:hedef`, çıplak korumalı dal,
    /// uzak silme), `fetch` ile yerel korumalı dalın ezilmesi, zorla temizlik
    /// ve zorla dal işlemi yakalanır. `--force-with-lease` güvenli varyanttır,
    /// korumalı olmayan dalda açık kalır. Ham jeton (`rawTokens`) yalnız büyük
    /// harf bayraklar içindir: boru hattı küçük harfe indirdiği için `-D`/`-d`
    /// orada ayırt edilemez.
    private static func isDestructiveGit(_ tokens: [String], rawTokens: [String]) -> Bool {
        if tokens.contains("reset") && tokens.contains("--hard") {
            return true
        }
        if tokens.contains("push") && isDestructivePush(tokens) {
            return true
        }
        if tokens.contains("fetch") && isDestructiveFetch(tokens) {
            return true
        }
        if tokens.contains("clean") && tokens.contains(where: { $0 == "--force" || isShortFlag($0, containing: "f") }) {
            return true
        }
        if (tokens.contains("checkout") || tokens.contains("switch")) && tokens.contains(where: isTreeWideTarget)
            && !tokens.contains(where: { $0 == "-p" || $0 == "--patch" })
        {
            return true
        }
        if tokens.contains("restore") && tokens.contains(where: isTreeWideTarget)
            && !(tokens.contains("--staged") && !tokens.contains("--worktree"))
        {
            return true
        }
        if isForceBranchOp(rawTokens) {
            return true
        }
        return false
    }

    /// Zorla gönderim ve korumalı dala yazım. İlk bayraksız konum remote adı
    /// sayılıp atlanır; en kötü halde yanlış konum atlanır, tehlike kalıpları
    /// konumsuz da yakalanır. `main`/`master` hedefine her yazım yasaktır:
    /// döngü korumalı dala insan onayı olmadan yazamaz.
    private static func isDestructivePush(_ tokens: [String]) -> Bool {
        var seenRemote = false
        for token in tokens {
            if token == "push" {
                continue
            }
            if token.hasPrefix("-") {
                if token == "--force" || isShortFlag(token, containing: "f") {
                    return true
                }
                if token == "--delete" || token == "-d" {
                    return true
                }
                continue
            }
            if !seenRemote {
                seenRemote = true
                continue
            }
            if token.hasPrefix("+") {
                return true
            }
            if token.contains(":") {
                let parts = token.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let src = parts.first ?? ""
                let dst = parts.last ?? ""
                // `:dal` uzak dal siler, `dal:` bozuk biçimdir: ikisi de kapalı.
                if src.isEmpty || dst.isEmpty || isProtectedRef(dst) {
                    return true
                }
                continue
            }
            if isProtectedRef(token) {
                return true
            }
        }
        return false
    }

    /// `fetch` ile yerel korumalı dalın ezilmesi (`main:main`). Düz `fetch`
    /// yalnızca uzaktan izleme dalını günceller, serbesttir.
    private static func isDestructiveFetch(_ tokens: [String]) -> Bool {
        tokens.contains(where: {
            guard $0.contains(":") else {
                return false
            }
            let dst = $0.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? ""
            return isProtectedRef(dst)
        })
    }

    /// Korumalı dal adı: `refs/heads/` öneki soyulur.
    private static func isProtectedRef(_ ref: String) -> Bool {
        var short = ref
        if short.hasPrefix("refs/heads/") {
            short = String(short.dropFirst("refs/heads/".count))
        }
        return short == "main" || short == "master"
    }

    /// Ağaç geneli hedef: `.`, `./`, `..` kaçışları ve `:/` kök sihri.
    /// Tek dosya/dal adı buraya düşmez.
    private static func isTreeWideTarget(_ token: String) -> Bool {
        if token == ":/" {
            return true
        }
        let normalized = normalizeRmTarget(token)
        return normalized == "." || normalized == ".." || normalized.hasPrefix("../") || normalized == "/"
    }

    /// Zorla dal işlemi: `-D`/`-B`/`-C` büyük harf zorlar, küçük harf güvenli
    /// varyanttır (`-d`/`-b`/`-c` açık kalır). Ham jetonla bakılır.
    private static func isForceBranchOp(_ rawTokens: [String]) -> Bool {
        guard rawTokens.contains("branch") || rawTokens.contains("checkout") || rawTokens.contains("switch") else {
            return false
        }
        return rawTokens.contains(where: { token in
            token == "-D" || token == "-B" || token == "-C"
                || (token.hasPrefix("-") && !token.hasPrefix("--")
                    && token.dropFirst().contains(where: { $0 == "D" || $0 == "B" || $0 == "C" }))
        })
    }

    /// Kapsamsız `find -delete`: kökümsü yolda (`/`, `.`) ve daraltıcı yüklem
    /// (`-name`, `-mtime`…) yokken tüm ağacı siler. Yüklemli temizlik serbesttir.
    private static func isDestructiveFind(_ tokens: [String]) -> Bool {
        guard tokens.contains("-delete") else {
            return false
        }
        let scoped = [
            "-name", "-iname", "-path", "-ipath", "-regex", "-iregex",
            "-mtime", "-mmin", "-atime", "-amin", "-ctime", "-cmin",
            "-size", "-type", "-empty", "-newer",
        ]
        if tokens.contains(where: { scoped.contains($0) }) {
            return false
        }
        let paths = tokens.filter { !$0.hasPrefix("-") }
        return paths.contains(where: isDestructiveRmTarget)
    }

    /// Bitişik kısa bayrakta harf arar (`-fdx` içinde `f`). `--` uzun bayraklar
    /// kapsam dışıdır (`--follow-tags` içindeki `f` sayılmaz).
    private static func isShortFlag(_ token: String, containing scalar: Character) -> Bool {
        token.hasPrefix("-") && !token.hasPrefix("--") && token.dropFirst().contains(scalar)
    }
}
