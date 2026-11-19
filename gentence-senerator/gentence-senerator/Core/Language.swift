import Foundation

/// Closed set. Every per-language decision resolves through here or
/// `LanguagePack`, so a fourth language is a compile error rather than a silent
/// fall-through to a generic default.
enum Language: String, Codable, Hashable, CaseIterable, Identifiable {
    case mandarin
    case german
    case french
    case spanish
    case korean

    var id: String { rawValue }

    /// Two letters: chapter ids, concept rows.
    var code: String {
        switch self {
        case .mandarin: return "zh"
        case .german:   return "de"
        case .french:   return "fr"
        case .spanish:  return "es"
        case .korean:   return "ko"
        }
    }

    var name: String {
        switch self {
        case .mandarin: return "Mandarin"
        case .german:   return "German"
        case .french:   return "French"
        case .spanish:  return "Spanish"
        case .korean:   return "Korean"
        }
    }

    var flag: String {
        switch self {
        case .mandarin: return "🇨🇳"
        case .german:   return "🇩🇪"
        case .french:   return "🇫🇷"
        case .spanish:  return "🇲🇽"
        case .korean:   return "🇰🇷"
        }
    }

    var localeID: String {
        switch self {
        case .mandarin: return "zh-CN"
        case .german:   return "de-DE"
        case .french:   return "fr-FR"
        case .spanish:  return "es-MX"
        case .korean:   return "ko-KR"
        }
    }

    /// Drives the phonetic rail, and nothing else. Not a stand-in for "is Mandarin".
    var needsPhoneticGloss: Bool {
        switch self {
        case .mandarin: return true
        case .german, .french, .spanish, .korean: return false
        }
    }

    /// Listen is ChinesePod dialogues; the others have none yet. Produce is
    /// the long one, there when wanted and never owed.
    var modes: [Mode] {
        switch self {
        case .mandarin: return [.translate, .reply, .listen, .produce]
        case .german, .french, .spanish, .korean: return [.translate, .reply, .produce]
        }
    }

    /// The day's modes: what has to be done for the day to be done.
    var dailyModes: [Mode] { modes.filter(\.isDaily) }

    /// Words split on spaces. Mandarin runs together and is compared by character.
    var usesSpaces: Bool { self != .mandarin }

    var levelSystem: String {
        switch self {
        case .mandarin: return "HSK"
        case .german, .french, .spanish: return "CEFR"
        case .korean: return "TOPIK"
        }
    }

    /// Set in the system face: Charter has no CJK or Hangul.
    var usesSystemFace: Bool {
        switch self {
        case .mandarin, .korean: return true
        case .german, .french, .spanish: return false
        }
    }
}
