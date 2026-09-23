import Foundation

/// Gönderim öncesi doğrulama ön kontrolü: ajan koşusu başlamadan çalışma
/// alanının güvenilir tarifeye çözülebileceğini söyler.
///
/// Çözülemeyen depo (tanınan işaret yok, `.git` bile yok) daha önce tam bir
/// ajan koşusu yakıp doğrulamada düşüyordu; bu kapı talebi (claim) geri
/// çekip ertelenmiş bir ret döner, koşu hiç doğmaz. `nil` bağlı değil
/// demektir: eski kompozisyonlar ve testler kapıyı atlar.
protocol TaskVerificationPreflightProviding: Sendable {
    /// Çözülemezse Türkçe eylemli gerekçe döner, çözülürse `nil`.
    func unresolvableReason(projectID: UUID, taskID: UUID) async -> String?
}
