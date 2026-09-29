import SwiftUI
import CoreText

/// Design tokens: "Typescript & Ledger". Every colour, face and rule in the app
/// resolves here; the components built from them are in `Ledger.swift`.
enum Theme {

    // MARK: Colour

    /// Paper, ink and rubber-stamp colours. Light / dark.
    enum C {
        static let ground   = dyn(0xECE5D5, 0x16140F)
        static let surface  = dyn(0xF6F1E4, 0x1F1C16)
        static let raised   = dyn(0xE1D8C3, 0x2A261E)
        static let sunk     = dyn(0xE5DDC9, 0x110F0B)
        /// Index-card stock.
        static let stock    = dyn(0xFAF6EC, 0x22201A)

        static let ink      = dyn(0x1E1C18, 0xE9E0CC)
        static let ink2     = dyn(0x5B564A, 0xA79D87)
        /// Darkened from the board's 8B8471 / 6F6756 to clear 4.5:1 on ground
        /// and surface; it is used for text.
        static let ink3     = dyn(0x686250, 0x948B75)

        static let seam     = dyn(0xCCBFA4, 0x3A3428)
        static let seam2    = dyn(0xA89A7D, 0x534A3B)
        /// Ledger ruling. Decorative: draw at ~45%.
        static let rule     = dyn(0x7D93A6, 0x4F6272)
        /// The red margin line. Decorative.
        static let margin   = dyn(0xB8472F, 0xC2604A)

        /// Actions and "you are here". Nothing else.
        static let accent     = dyn(0xA8481A, 0xD4703C)
        static let accentDeep = dyn(0x6E2A0E, 0x3A1508)
        static let onAccent   = dyn(0xFBF6F1, 0x191008)

        static let good     = dyn(0x3E5D39, 0x8FAE72)
        static let warn     = dyn(0x946A1C, 0xCFA048)
        static let bad      = dyn(0x9C2E21, 0xD0664F)
        /// Carbon-copy blue: reference text only.
        static let carbon   = dyn(0x4A4E7C, 0x9DA2D6)

        /// Dark slips and bars; dark in both modes.
        static let inverse     = dyn(0x23251F, 0x0E0F0C)
        static let inverseDeep = dyn(0x0B0C09, 0x000000)
        static let onInverse   = dyn(0xE3E1D5, 0xE3E1D5)
        /// The accent where it sits on `inverse`.
        static let accentOnInverse = dyn(0xD4703C, 0xD4703C)

        static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
            Color(uiDyn(light, dark))
        }

        static func uiDyn(_ light: UInt32, _ dark: UInt32) -> UIColor {
            UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) }
        }

        private static func ui(_ hex: UInt32) -> UIColor {
            UIColor(red:   CGFloat((hex >> 16) & 0xFF) / 255,
                    green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue:  CGFloat(hex & 0xFF) / 255,
                    alpha: 1)
        }
    }

    /// Findings are coloured by consequence, not by category.
    static func colour(for verdict: Atom.Verdict) -> Color {
        switch verdict {
        case .breaks:  return C.bad
        case .weakens: return C.warn
        case .kept:    return C.good
        }
    }

    /// A 0–100 score as a stamp colour.
    static func band(_ score: Int) -> Color {
        score >= 80 ? C.good : score >= 50 ? C.warn : C.bad
    }

    // MARK: Type

    /// Courier Prime for labels, counts and measurements; Charter for anything
    /// read as prose; Mandarin always in the system sans.
    enum F {
        /// Big typed numerals: 151 / 262.
        static let display    = mono(36, bold: true)
        /// Page titles.
        static let title      = serif(22, bold: true)
        /// Tiles and keys that carry a name. Allow two lines.
        static let cardTitle  = serif(17, bold: true)
        static let body       = serif(16)
        static let bodyTight  = serif(14.5)
        /// Secondary prose. Pair with `ink2`.
        static let note       = serif(13)
        /// English gloss under target text. Pair with `ink2`.
        static let gloss      = serif(13, italic: true)
        /// Values: counts, times, lowercase readouts.
        static let meta       = mono(11)
        /// CAPS names. Use `.monoCaps()` for the tracking and case.
        static let label      = mono(11, bold: true)
        /// Mid-size typed number.
        static let number     = mono(20, bold: true)

        /// Target-language text for the language being learned now.
        static var target: Font { target(for: ThemeState.shared.language) }
        static var targetSmall: Font { targetSmall(for: ThemeState.shared.language) }

        static func target(for language: Language) -> Font {
            target(size: 22, for: language)
        }

        static func targetSmall(for language: Language) -> Font {
            target(size: 17, for: language)
        }

        /// Target text at any size. Mandarin gets the system face (PingFang):
        /// a serif CJK is hard to read.
        static func target(size: CGFloat, bold: Bool = false,
                           for language: Language = ThemeState.shared.language) -> Font {
            language == .mandarin
                ? .system(size: size, weight: bold ? .semibold : .regular)
                : serif(size, bold: bold)
        }

        static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
            face(bold ? "CourierPrime-Bold" : "CourierPrime-Regular", size, bold: bold)
        }

        static func serif(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> Font {
            let name = switch (bold, italic) {
            case (false, false): "Charter-Roman"
            case (true, false):  "Charter-Bold"
            case (false, true):  "Charter-Italic"
            case (true, true):   "Charter-BoldItalic"
            }
            return face(name, size, bold: bold)
        }

        /// A named face whose missing glyphs fall to PingFang, so Chinese inside
        /// Charter or Courier never lands on a serif CJK face.
        private static func face(_ name: String, _ size: CGFloat, bold: Bool) -> Font {
            let cjk = UIFontDescriptor(name: bold ? "PingFangSC-Semibold" : "PingFangSC-Regular", size: size)
            let descriptor = UIFontDescriptor(name: name, size: size)
                .addingAttributes([.cascadeList: [cjk]])
            return Font(UIFont(descriptor: descriptor, size: size) as CTFont)
        }
    }

    // MARK: Metric

    enum M {
        static let hair: CGFloat = 1
        static let pad: CGFloat = 12
        static let padTight: CGFloat = 9
        static let gap: CGFloat = 16
        static let gapTight: CGFloat = 8
        /// Zero everywhere. Nothing in this app is a rounded card.
        static let radius: CGFloat = 0
        /// The coloured edge that marks a finding's consequence.
        static let edge: CGFloat = 3
        /// A key's hard shadow.
        static let drop: CGFloat = 3
        /// Tracking for CAPS mono labels.
        static let caps: CGFloat = 0.8
    }

    // MARK: Setup

    /// Bundled fonts and UIKit chrome. Once, at launch.
    static func install() {
        for name in ["CourierPrime-Regular", "CourierPrime-Bold"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: "ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }

        let bar = UINavigationBarAppearance()
        bar.configureWithOpaqueBackground()
        bar.backgroundColor = C.uiDyn(0xECE5D5, 0x16140F)
        bar.shadowColor = C.uiDyn(0xCCBFA4, 0x3A3428)
        let ink = C.uiDyn(0x1E1C18, 0xE9E0CC)
        if let charter = UIFont(name: "Charter-Bold", size: 17) {
            bar.titleTextAttributes = [.font: charter, .foregroundColor: ink]
        }
        if let charter = UIFont(name: "Charter-Bold", size: 30) {
            bar.largeTitleTextAttributes = [.font: charter, .foregroundColor: ink]
        }
        UINavigationBar.appearance().standardAppearance = bar
        UINavigationBar.appearance().scrollEdgeAppearance = bar
        UINavigationBar.appearance().compactAppearance = bar
    }
}

/// What the theme needs to know about the app. Observable, so a view that
/// reads `Theme.F.target` redraws when the language changes. Set by the shell.
@Observable
final class ThemeState {
    static let shared = ThemeState()
    var language: Language = .german
}

/// Autocorrect is trained on the interface language, so it rewrites the
/// language being learned into English-looking words. Every field that takes
/// target-language input turns it off.
extension View {
    func targetLanguageInput() -> some View {
        self
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .keyboardType(.default)
    }
}
