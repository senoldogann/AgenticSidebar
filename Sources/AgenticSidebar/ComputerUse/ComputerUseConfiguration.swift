import Foundation

/// chatgpt-system deposu çözümlenemediğinde kullanıcıya gösterilecek hatalar.
enum ComputerUseConfigurationError: Error, Equatable, Sendable {
    case emptyRootPath
    case cliMissing(path: String)
    case nodeMissing

    var message: String {
        switch self {
        case .emptyRootPath:
            "Set the chatgpt-system folder path."
        case .cliMissing(let path):
            "dist/cli.js was not found at \(path). Run `npm run build` and check the path."
        case .nodeMissing:
            "Node.js was not found. Install Node.js (Homebrew: `brew install node`)."
        }
    }
}

/// OpenCode sunucusu başlatılırken bilgisayar kullanımının durumu.
enum ComputerUseLaunchDecision: Equatable, Sendable {
    case disabled
    case invalid(message: String)
    case ready(ComputerUseConfiguration)
}

/// Yönetilen OpenCode sunucusuna MCP istemcisi olarak bağlanacak
/// chatgpt-system sürecinin çözümlenmiş yapılandırması.
///
/// chatgpt-system deposuna hiçbir şey yazılmaz; yalnızca okunur ve süreç
/// OpenCode tarafından `POST /mcp` kaydındaki komutla başlatılır.
struct ComputerUseConfiguration: Equatable, Sendable {
    let projectRootURL: URL
    let nodeExecutableURL: URL
    let workingDirectoryURL: URL

    static let serverName = "chatgpt-system"
    static let toolPrefix = "chatgpt-system_"
    static let nodeExecutableCandidates = [
        "/opt/homebrew/bin/node",
        "/usr/local/bin/node",
        "/usr/bin/node",
    ]

    /// PATH'ten node aranabilecek dizinler: yalnızca sistem dizinleri ve
    /// uygulama paketi içi. Kullanıcının PATH'indeki yazılabilir dizinlerden
    /// (Homebrew ön eki, nvm shimi, proje klasörleri) çalıştırılabilir almak,
    /// o dizine yazabilen herkesin kodunu bu uygulamanın yetkisiyle çalıştırmak
    /// olur; sabit adaylar (`nodeExecutableCandidates`) bu kuralın dışındadır,
    /// çünkü onlar kullanıcının yazdığı bir listeden değil, koddan gelir.
    static let trustedSystemDirectories: Set<String> = [
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ]

    var cliURL: URL {
        projectRootURL
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("cli.js")
    }

    var helperBundleURL: URL {
        Self.helperBundleURL(homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// Bilgisayar kontrolünü yapan imzalı yardımcı uygulamanın yolu; çözümleme
    /// başarısız olsa bile kullanıcıya gösterilebilir.
    static func helperBundleURL(homeDirectoryURL: URL) -> URL {
        homeDirectoryURL
            .appendingPathComponent(".chatgpt-system", isDirectory: true)
            .appendingPathComponent("ChatGPTSystemComputerRuntime.app", isDirectory: true)
    }

    /// MCP sunucusunu OpenCode'da kaydederken kullanılan komut.
    ///
    /// `--personal-admin` Admin lease'i Touch ID olmadan açar; yetki yine
    /// lease ömrüyle ve her `computer_*` çağrısındaki kullanıcı onayıyla sınırlı
    /// kalır. `--enable-full-host-js` bilinçli olarak eklenmez.
    func mcpServerConfig() -> OpenCodeMCPServerConfig {
        OpenCodeMCPServerConfig(
            type: "local",
            command: [
                nodeExecutableURL.path,
                cliURL.path,
                "stdio",
                "--root", workingDirectoryURL.path,
                "--personal-admin",
                "--enable-computer-use",
            ],
            environment: nil,
            enabled: true,
            timeout: 20_000
        )
    }

    /// Ayar değerlerinden OpenCode başlatma kararını üretir.
    static func decision(
        enabled: Bool,
        rootPath: String,
        workingDirectoryURL: URL,
        environment: [String: String],
        fileManager: FileManager,
        bundlePath: String
    ) -> ComputerUseLaunchDecision {
        guard enabled else {
            return .disabled
        }

        switch resolve(
            rootPath: rootPath,
            workingDirectoryURL: workingDirectoryURL,
            environment: environment,
            fileManager: fileManager,
            bundlePath: bundlePath
        ) {
        case .success(let configuration):
            return .ready(configuration)
        case .failure(let error):
            return .invalid(message: error.message)
        }
    }

    static func resolve(
        rootPath: String,
        workingDirectoryURL: URL,
        environment: [String: String],
        fileManager: FileManager,
        bundlePath: String
    ) -> Result<ComputerUseConfiguration, ComputerUseConfigurationError> {
        let expanded = expand(
            rootPath: rootPath,
            homeDirectoryURL: fileManager.homeDirectoryForCurrentUser
        )
        guard !expanded.isEmpty else {
            return .failure(.emptyRootPath)
        }

        let projectRootURL = URL(fileURLWithPath: expanded, isDirectory: true)
        let cliURL =
            projectRootURL
            .appendingPathComponent("dist", isDirectory: true)
            .appendingPathComponent("cli.js")

        guard fileManager.fileExists(atPath: cliURL.path) else {
            return .failure(.cliMissing(path: cliURL.path))
        }

        guard
            let nodeExecutableURL = locateNode(
                environment: environment,
                fileManager: fileManager,
                candidatePaths: Self.nodeExecutableCandidates,
                bundlePath: bundlePath
            )
        else {
            return .failure(.nodeMissing)
        }

        return .success(
            ComputerUseConfiguration(
                projectRootURL: projectRootURL,
                nodeExecutableURL: nodeExecutableURL,
                workingDirectoryURL: workingDirectoryURL
            )
        )
    }

    static func expand(rootPath: String, homeDirectoryURL: URL) -> String {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        if trimmed == "~" {
            return homeDirectoryURL.path
        }
        if trimmed.hasPrefix("~/") {
            return
                homeDirectoryURL
                .appendingPathComponent(String(trimmed.dropFirst(2)))
                .path
        }
        return trimmed
    }

    /// PATH girdilerini güvenli kümeye indirger: boş, göreli ve `..` içeren
    /// girdiler elenir; kalanlardan yalnızca sistem dizinleri ve uygulama
    /// paketi içindekiler tutulur. Sıra korunur, tekrarlar atılır.
    static func sanitizedSearchDirectories(
        environment: [String: String],
        bundlePath: String
    ) -> [String] {
        let rawEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        var kept: [String] = []
        let bundlePrefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
        for entry in rawEntries {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            // Göreli girdiler çağrıldığı dizine göre çözülür; allowlist dışı bırakılır.
            guard trimmed.hasPrefix("/") else {
                continue
            }
            let components = trimmed.split(separator: "/").map(String.init)
            guard !components.contains("..") else {
                continue
            }
            let normalized = "/" + components.joined(separator: "/")
            let allowed =
                trustedSystemDirectories.contains(normalized)
                || normalized == bundlePath
                || normalized.hasPrefix(bundlePrefix)
            guard allowed, seen.insert(normalized).inserted else {
                continue
            }
            kept.append(normalized)
        }
        return kept
    }

    static func locateNode(
        environment: [String: String],
        fileManager: FileManager,
        candidatePaths: [String],
        bundlePath: String
    ) -> URL? {
        for candidate in candidatePaths
        where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }

        let pathEntries = sanitizedSearchDirectories(
            environment: environment,
            bundlePath: bundlePath
        )

        for entry in pathEntries {
            let candidate = URL(fileURLWithPath: entry, isDirectory: true)
                .appendingPathComponent("node")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }
}
