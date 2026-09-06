import SwiftUI

/// Design tokens. Every colour, size and rule in the app resolves here.
enum Theme {

    // MARK: Colour

    /// Warm olive-grey neutrals biased toward the accent, so nothing reads as
    /// default system grey.
    enum C {
        static let ground   = dyn(0xE7E4DB, 0x191B16)
        static let surface  = dyn(0xF2F0E8, 0x20231E)
        static let raised   = dyn(0xDCD8CB, 0x2A2E27)
        static let sunk     = dyn(0xDEDBD0, 0x161814)

        static let ink      = dyn(0x23251F, 0xE3E1D5)
        static let ink2     = dyn(0x61645A, 0x9B9D8E)
        static let ink3     = dyn(0x8A8C7E, 0x6D7063)

        static let seam     = dyn(0xC4C0B2, 0x373A32)
        static let seam2    = dyn(0xAAA697, 0x4B4E44)

        static let accent   = dyn(0xA8481A, 0xD4703C)
        static let onAccent = dyn(0xFBF6F1, 0x191008)

        static let good     = dyn(0x4F6B3C, 0x93AC74)
        static let warn     = dyn(0x8E6A1B, 0xC99C3E)
        static let bad      = dyn(0x963425, 0xCB6C56)

        static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .dark ? ui(dark) : ui(light) })
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

    // MARK: Type

    /// Monospace for anything that is a label, a count or a measurement;
    /// proportional for anything read as language.
    enum F {
        static let label      = Font.system(size: 10, weight: .medium, design: .monospaced)
        static let meta       = Font.system(size: 11, design: .monospaced)
        static let number     = Font.system(size: 20, weight: .regular, design: .monospaced)
        static let body       = Font.system(size: 15)
        static let bodyTight  = Font.system(size: 13.5)
        static let note       = Font.system(size: 12.5)
        static let title      = Font.system(size: 19, weight: .semibold)
        /// Target-language text, set larger — a learner needs to see the strokes.
        static let target     = Font.system(size: 22)
        static let targetSmall = Font.system(size: 17)
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
    }
}

// MARK: - Shared chrome

/// Uppercase monospace caption with a rule running to the trailing edge.
/// The only section-header treatment in the app.
struct ModuleLabel: View {
    let text: String
    var body: some View {
        HStack(spacing: Theme.M.gapTight) {
            Text(text.uppercased())
                .font(Theme.F.label)
                .tracking(1.1)
                .foregroundStyle(Theme.C.ink3)
            Rectangle()
                .fill(Theme.C.seam)
                .frame(height: Theme.M.hair)
        }
    }
}

/// Hairline box with an optional coloured leading edge.
struct Panel<Content: View>: View {
    var fill: Color = Theme.C.surface
    var edge: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.M.pad)
            .padding(.leading, edge == nil ? 0 : Theme.M.edge)
            .background(fill)
            // As an overlay rather than a sibling: a Rectangle in an HStack is
            // greedy vertically and stretches the panel to fill the screen.
            .overlay(alignment: .leading) {
                if let edge {
                    Rectangle().fill(edge).frame(width: Theme.M.edge)
                }
            }
            .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
    }
}

/// Small bordered action. Used for every secondary control.
struct TinyButton: View {
    let title: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Theme.F.label)
                .tracking(0.9)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .foregroundStyle(selected ? Theme.C.onAccent : Theme.C.ink)
                .background(selected ? Theme.C.accent : Theme.C.surface)
                .overlay(
                    Rectangle().stroke(selected ? Theme.C.accent : Theme.C.seam2,
                                       lineWidth: Theme.M.hair)
                )
        }
        .buttonStyle(.plain)
    }
}

/// Full-width primary action.
struct MainButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.F.body.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .foregroundStyle(enabled ? Theme.C.onAccent : Theme.C.ink3)
                .background(enabled ? Theme.C.accent : Theme.C.raised)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
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
