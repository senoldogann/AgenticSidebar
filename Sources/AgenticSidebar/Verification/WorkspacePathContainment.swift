import Foundation

/// Çalışma alanı dışına taşan göreli yollar için tek doğruluk kaynağı.
///
/// `VerificationResolver` (tarif doğrulama) ve `VerificationRunner` (adım
/// çalışma dizini) aynı denetimi ayrı kopyalarla yapıyordu: ikisi de
/// `standardizedFileURL` kullanıyor, sembolik bağ çözmüyordu. Oysa çalışma
/// alanı içindeki bir bağ (`workspace/evil` → `/etc`) öneki tutturur ama
/// diske dışarıyı yazar. Bu helper yolu bileşen bileşen yürüyüp her adımdaki
/// bağı izler; reddetme yönü korunur (bilinmeyen = kaçış).
///
/// Neden adım adım: `resolvingSymlinksInPath` tek çağrıda, var olmayan bir
/// kuyruk varken aradaki bağı çözmez (`ws/evil/nested`, `evil` varken bile
/// sözcüksel kalır ve önek tutar). Her bileşen eklendikçe çözülürse kaçış
/// yakalanır.
enum WorkspacePathContainment {
    /// Göreli yol mutlaksa, `..` içeriyorsa ya da bağ çözümü sonrası çalışma
    /// alanının dışına taşıyorsa `true` döner.
    static func relativePath(_ path: String, escapesWorkspace workspace: URL) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.hasPrefix("/") else { return true }
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !components.contains("..") else { return true }
        let root = workspace.resolvingSymlinksInPath().standardized.path
        var current = root
        for name in components {
            if name == "." || name.isEmpty {
                continue
            }
            current += "/" + name
            current = Self.resolveOneStep(current)
            if current != root, !current.hasPrefix(root + "/") {
                return true
            }
        }
        return false
    }

    /// Tek adımın çözümü: son bileşen bir bağsa (sarkan bağ dahil) hedefi
    /// izlenir, değilse var olan önek çözülür. Döngü riski yoktur — bağ
    /// zinciri bileşen sayısıyla sınırlı tek adımlarla izlenir.
    private static func resolveOneStep(_ path: String) -> String {
        if let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            let next: String
            if destination.hasPrefix("/") {
                next = destination
            } else {
                let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
                next = parent + "/" + destination
            }
            return URL(fileURLWithPath: next).resolvingSymlinksInPath().standardized.path
        }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().standardized.path
    }
}
