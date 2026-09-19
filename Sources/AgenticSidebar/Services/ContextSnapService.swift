import AppKit
import ApplicationServices
import Foundation

/// Öndeki uygulamanın o anki bağlamının taşınabilir görüntüsü.
///
/// Üç katmanlı degrade: uygulama + pencere başlığı her zaman (TCC gerektirmez),
/// URL yalnızca Otomasyon izni varsa, seçili metin yalnızca Erişilebilirlik
/// izni varsa. İzin yoksa ilgili alan `nil` kalır, snap yine de kurulur.
struct ContextSnap: Equatable, Sendable {
    let appName: String
    let windowTitle: String?
    let url: String?
    let selectedText: String?
    let capturedAt: Date

    /// Seçili metnin markdown içinde taşınan üst sınırı.
    nonisolated static let maximumSelectedCharacters = 4_000

    /// Composer'a `requestRestore` ile verilecek metin.
    func markdown() -> String {
        var lines = ["<!-- context-snap · \(appName) -->"]
        lines.append("**App:** \(appName)")
        if let windowTitle, !windowTitle.isEmpty {
            lines.append("**Window:** \(windowTitle)")
        }
        if let url, !url.isEmpty {
            lines.append("**URL:** \(url)")
        }
        if let selectedText {
            let trimmed = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let clipped =
                    trimmed.count > Self.maximumSelectedCharacters
                    ? String(trimmed.prefix(Self.maximumSelectedCharacters)) + "\n[…kırpıldı]"
                    : trimmed
                let fence = Self.codeFence(for: clipped)
                lines.append("**Selected:**\n\(fence)\n\(clipped)\n\(fence)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// İçerikteki en uzun ters-tırnak koşusundan bir uzun çit seçer; seçili
    /// metin ``` içeriyorsa bloğu kırmaz.
    static func codeFence(for text: String) -> String {
        var longest = 0
        var run = 0
        for character in text {
            if character == "`" {
                run += 1
                longest = max(longest, run)
            } else {
                run = 0
            }
        }
        return String(repeating: "`", count: max(3, longest + 1))
    }
}

/// Enjekte edilebilir ön-uç okuyucular; üretimde sistem, testte taklit.
protocol ContextFrontmostAppProvider: Sendable {
    /// Ad + pencere başlığı; öndeki uygulama okunamazsa `nil`.
    func frontmost() -> (appName: String, windowTitle: String?)?
}

protocol ContextBrowserURLProvider: Sendable {
    /// Öndeki sekmenin URL'si; tarayıcı değilse ya da izin yoksa `nil`.
    func url() -> String?
}

protocol ContextSelectedTextProvider: Sendable {
    /// Odaktaki öğenin seçili metni; izin yoksa `nil`.
    func selectedText() -> String?
}

struct ContextSnapService: Sendable {
    let appProvider: any ContextFrontmostAppProvider
    let urlProvider: any ContextBrowserURLProvider
    let textProvider: any ContextSelectedTextProvider

    /// - Returns: Öndeki uygulama bilinmiyorsa `nil`; yoksa en az
    ///   uygulama adlı bir snap (başlık-degrade).
    func snap() -> ContextSnap? {
        guard let frontmost = appProvider.frontmost() else {
            return nil
        }
        return ContextSnap(
            appName: frontmost.appName,
            windowTitle: frontmost.windowTitle,
            url: urlProvider.url(),
            selectedText: textProvider.selectedText(),
            capturedAt: Date()
        )
    }

    /// Üretim okuyucularıyla hazır kurulum.
    static func live() -> ContextSnapService {
        ContextSnapService(
            appProvider: SystemFrontmostAppProvider(),
            urlProvider: AppleScriptBrowserURLProvider(),
            textProvider: AXSelectedTextReader()
        )
    }
}

// MARK: - Üretim okuyucuları

/// NSWorkspace + CGWindowList; TCC izni gerektirmez.
struct SystemFrontmostAppProvider: ContextFrontmostAppProvider {
    func frontmost() -> (appName: String, windowTitle: String?)? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
        return (name, Self.windowTitle(forPID: app.processIdentifier))
    }

    private static func windowTitle(forPID pid: pid_t) -> String? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        return firstWindowTitle(forPID: pid, in: list)
    }

    /// Pencere listesinden başlık seçimi (saf; test edilebilir).
    ///
    /// PID karşılaştırması `NSNumber` üzerinden yapılır: `CGWindowList`
    /// değerleri `CFNumber` taşır ve `as? Int32` kalıbı köprülemede tutmayıp
    /// başlığı sessizce `nil` bırakabilirdi.
    static func firstWindowTitle(forPID pid: pid_t, in entries: [[String: Any]]) -> String? {
        for entry in entries {
            guard let owner = entry[kCGWindowOwnerPID as String] as? NSNumber,
                owner.int32Value == pid,
                (entry[kCGWindowLayer as String] as? Int) == 0,
                let title = entry[kCGWindowName as String] as? String,
                !title.isEmpty
            else {
                continue
            }
            return title
        }
        return nil
    }
}

/// Safari/Chrome etkin sekme URL'si (AppleEvent → Otomasyon TCC gerekir).
struct AppleScriptBrowserURLProvider: ContextBrowserURLProvider {
    func url() -> String? {
        // Eşzamanlı AppleEvent ana işi saniyeler tutabilir; çağıran detached
        // görevden `urlAsync()` kullanmalı, bu yol uyumluluk içindir.
        return Self.urlSync()
    }

    /// 2 sn zaman aşımlı arka plan okuma.
    func urlAsync() async -> String? {
        await withTaskGroup(of: String?.self, returning: String?.self) { group in
            group.addTask(priority: .utility) {
                await Task.detached(priority: .utility) { Self.urlSync() }.value
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            for await result in group {
                group.cancelAll()
                return result
            }
            return nil
        }
    }

    private static func urlSync() -> String? {
        guard let frontmost = NSWorkspace.shared.frontmostApplication,
            let bundleID = frontmost.bundleIdentifier
        else {
            return nil
        }
        let source: String
        switch bundleID {
        case "com.apple.Safari":
            source = "tell application \"Safari\" to get URL of current tab of front window"
        case "com.google.Chrome", "com.google.Chrome.canary", "com.microsoft.edgemac", "com.brave.Browser", "com.arc.Browser":
            source = "tell application id \"\(bundleID)\" to get URL of active tab of front window"
        default:
            return nil
        }
        guard let script = NSAppleScript(source: source) else {
            return nil
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else {
            return nil
        }
        let url = result.stringValue
        return (url?.isEmpty == false) ? url : nil
    }
}

/// Odaktaki erişilebilirlik öğesinin seçili metni (Erişilebilirlik TCC gerekir).
struct AXSelectedTextReader: ContextSelectedTextProvider {
    func selectedText() -> String? {
        guard AXIsProcessTrusted() else {
            return nil
        }
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &focused
            ) == .success, let element = focused
        else {
            return nil
        }
        var selected: CFTypeRef?
        // Odak öğesi dış süreçten gelir: türü doğrulanmadan indirgenemez.
        // `CFGetTypeID` uyuşmazsa `nil` dönülür, tuzak kurulmaz.
        let rawElement = element as CFTypeRef
        guard CFGetTypeID(rawElement) == AXUIElementGetTypeID() else {
            return nil
        }
        let axElement = unsafeDowncast(rawElement, to: AXUIElement.self)
        guard
            AXUIElementCopyAttributeValue(
                axElement,
                kAXSelectedTextAttribute as CFString,
                &selected
            ) == .success
        else {
            return nil
        }
        guard let text = selected as? String, !text.isEmpty else {
            return nil
        }
        return text
    }
}
