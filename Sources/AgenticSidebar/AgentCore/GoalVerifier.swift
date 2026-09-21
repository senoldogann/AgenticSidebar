import Foundation

/// Bitiş kapılarının saf girdisi: dört kapı birden yeşil olmadan bitti denmez.
struct GoalGateInput: Equatable, Sendable {
    let buildSucceeded: Bool
    let testsSucceeded: Bool
    let criticalOrHighFindings: Int
    let unmetCriteria: Int
}

/// Kapı kararı: ya bitti, ya da gerekçeli düzeltme turu.
enum GoalGateDecision: Equatable, Sendable {
    case done
    case fixing(reasons: [String])
}

/// Review yanıtındaki `CRITICAL_HIGH_COUNT: N` satırının saf okuyucusu:
/// G/Ç yapmaz, yalnızca sayı üretir. Son eşleşme kazanır (hüküm cümlesi
/// sondadır); eşleşme yoksa ya da yanıt yoksa 0 döner.
enum GoalReviewFindings {
    static func count(from text: String?) -> Int {
        guard let text, !text.isEmpty else {
            return 0
        }
        var last: Int?
        var remainder = text[text.startIndex..<text.endIndex]
        while let range = remainder.range(
            of: #"CRITICAL_HIGH_COUNT\s*:\s*(\d+)"#,
            options: [.regularExpression, .caseInsensitive]
        ) {
            let match = String(remainder[range])
            let digits = match.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if let value = Int(digits) {
                last = value
            }
            remainder = remainder[range.upperBound..<remainder.endIndex]
        }
        return last ?? 0
    }
}
/// Dört kapının konjonktif (VE) değerlendirmesi: tek kırmızı yetmez, dördü
/// birden yeşil gerekir. Saf fonksiyondur, G/Ç yapmaz.
enum GoalVerifier {
    static func evaluate(_ input: GoalGateInput) -> GoalGateDecision {
        var reasons: [String] = []
        if !input.buildSucceeded {
            reasons.append("build failed")
        }
        if !input.testsSucceeded {
            reasons.append("tests failed")
        }
        if input.criticalOrHighFindings > 0 {
            reasons.append("\(input.criticalOrHighFindings) critical/high review findings open")
        }
        if input.unmetCriteria > 0 {
            reasons.append("\(input.unmetCriteria) acceptance criteria unmet")
        }
        if reasons.isEmpty {
            return .done
        }
        return .fixing(reasons: reasons)
    }
}
