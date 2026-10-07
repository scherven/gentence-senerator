import Foundation

/// Closed set. Every per-language decision resolves through here or
/// `LanguagePack`, so a fourth language is a compile error rather than a silent
/// fall-through to a generic default.
enum Language: String, Codable, Hashable, CaseIterable, Identifiable {
    case mandarin
    case german
    case french

    var id: String { rawValue }

    var name: String {
        switch self {
        case .mandarin: return "Mandarin"
        case .german:   return "German"
        case .french:   return "French"
        }
    }

    var flag: String {
        switch self {
        case .mandarin: return "🇨🇳"
        case .german:   return "🇩🇪"
        case .french:   return "🇫🇷"
        }
    }

    var localeID: String {
        switch self {
        case .mandarin: return "zh-CN"
        case .german:   return "de-DE"
        case .french:   return "fr-FR"
        }
    }

    /// Drives the phonetic rail, and nothing else. Not a stand-in for "is Mandarin".
    var needsPhoneticGloss: Bool {
        switch self {
        case .mandarin: return true
        case .german, .french: return false
        }
    }

    /// Listen is ChinesePod dialogues; German and French have none yet.
    var modes: [Mode] {
        switch self {
        case .mandarin: return Mode.allCases
        case .german, .french: return [.translate, .produce]
        }
    }

    var levelSystem: String {
        switch self {
        case .mandarin: return "HSK"
        case .german, .french: return "CEFR"
        }
    }
}
