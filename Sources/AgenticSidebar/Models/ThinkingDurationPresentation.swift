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

        if hasRunningChildren {
            let totalSeconds = seconds(from: startedAt, to: now)
            return "Thought for \(format(thoughtSeconds)) · Working (\(format(totalSeconds)))"
        }

        let turnEnd = turnEndedAt ?? completedAt ?? now
        let totalSeconds = seconds(from: startedAt, to: turnEnd)

        guard totalSeconds > thoughtSeconds else {
            return "Thought for \(format(thoughtSeconds))"
        }

        return "Thought for \(format(thoughtSeconds)) · Worked \(format(totalSeconds))"
    }

    /// Geçen saniye. Saat geri alınmış olsa bile negatif bir süre gösterilmez ve
    /// bir saniyenin altı "0s" değil "1s" okunur.
    private static func seconds(from startedAt: Date, to endedAt: Date) -> Int {
        max(1, Int(endedAt.timeIntervalSince(startedAt)))
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
