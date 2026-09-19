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
