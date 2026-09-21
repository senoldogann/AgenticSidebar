import Foundation

/// Zaman çizelgesindeki düşünme satırının metni.
///
/// Ölçüm görünümün içindeyken test edilemiyordu; saf bir fonksiyona taşındı,
/// böylece "Thought for Ns" hesabı bir görünüm çalıştırmadan doğrulanabilir.
enum ThinkingDurationPresentation {
    /// Düşünme satırında gösterilecek metin.
    ///
    /// - `startedAt`: düşünmenin başladığı an.
    /// - `completedAt`: düşünmenin bittiği an; hâlâ sürüyorsa `nil`.
    /// - `turnEndedAt`: turun son aktivitesinin bittiği an; turdaki araçlar
    ///   düşünme bitiminden sonra da çalışabildiği için toplam süre buradan
    ///   okunur. Tur bilgisi yoksa `nil` geçilir.
    /// - `hasRunningChildren`: düşünme bitti ama turun araçları hâlâ çalışıyor.
    /// - `now`: ölçümün yapıldığı an.
    /// Kartın çizmeye değer içeriği var mı: reasoning paylaşmayan modellerde
    /// `output` hiç dolmaz. Karar bilinçli olarak "gizle"dir — boş bir
    /// "Thought" kutusu veya süre rozeti gürültüden ibarettir, placeholder
    /// metin eklenmez.
    static func hasVisibleContent(output: String?) -> Bool {
        guard let output else {
            return false
        }
        return !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func text(
        startedAt: Date,
        completedAt: Date?,
        turnEndedAt: Date?,
        isRunning: Bool,
        hasRunningChildren: Bool,
        now: Date
    ) -> String {
        if isRunning {
            return "Thinking for \(format(seconds(from: startedAt, to: now)))..."
        }

        let thoughtSeconds = seconds(from: startedAt, to: completedAt ?? turnEndedAt ?? now)
        return "Thought for \(format(thoughtSeconds))"
    }

    /// Satır başlığı için kısa biçim: bitince `Thought 10s`, koşarken
    /// `Thinking 3s`. `text` ile aynı ölçümü kullanır, yalnız sözdizimi
    /// kısadır.
    static func compactText(
        startedAt: Date,
        completedAt: Date?,
        turnEndedAt: Date?,
        isRunning: Bool,
        hasRunningChildren: Bool,
        now: Date
    ) -> String {
        if isRunning {
            return "Thinking \(format(seconds(from: startedAt, to: now)))"
        }

        let thoughtSeconds = seconds(from: startedAt, to: completedAt ?? turnEndedAt ?? now)
        return "Thought \(format(thoughtSeconds))"
    }

    /// Geçen saniye. Saat geri alınmış olsa bile negatif bir süre gösterilmez ve
    /// bir saniyenin altı "0s" değil "1s" okunur.
    private static func seconds(from startedAt: Date, to endedAt: Date) -> Int {
        let interval = endedAt.timeIntervalSince(startedAt)
        guard interval.isFinite else {
            return 1
        }
        return max(1, Int(interval))
    }

    /// Kısa süreler saniye, dakikayı aşanlar "4m 12s", saati aşanlar "1h 2m"
    /// okunur; uzun turlar "252s" gibi sayılmaz.
    private static func format(_ totalSeconds: Int) -> String {
        if totalSeconds < 60 {
            return "\(totalSeconds)s"
        }

        if totalSeconds < 3_600 {
            let minutes = totalSeconds / 60
            let seconds = totalSeconds % 60
            guard seconds > 0 else {
                return "\(minutes)m"
            }
            return "\(minutes)m \(seconds)s"
        }

        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        var text = "\(hours)h"
        if minutes > 0 || seconds > 0 {
            text += " \(minutes)m"
        }
        if seconds > 0 {
            text += " \(seconds)s"
        }
        return text
    }
}
