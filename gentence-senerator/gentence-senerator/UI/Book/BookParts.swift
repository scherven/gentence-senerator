import SwiftUI

/// Where the Book tab's stack can go. Lessons ride on `store.path`, so every
/// link inside one keeps working; they always sit above these.
enum BookRoute: Hashable {
    case chapter(String)
    case entry(chapter: String, entry: String)
    case lesson(LessonRequest)
}

extension EnvironmentValues {
    /// Starts a quiz over whatever is on screen. Set by the shell.
    @Entry var startQuiz: (QuizPlan) -> Void = { _ in }
    /// Opens the ALL LANGUAGES deck. Set by the shell.
    @Entry var startAllLanguages: () -> Void = {}
}

enum BookColour {
    /// The first tag seen reads in the accent, the second in ink: AKK / DAT,
    /// AVOIR / ÊTRE.
    static func tag(_ tag: String?, among tags: [String]) -> Color {
        guard let tag else { return Theme.C.ink2 }
        switch tag.uppercased() {
        case "AKK", "AVOIR": return Theme.C.accent
        case "DAT", "ÊTRE", "ETRE": return Theme.C.ink
        default: break
        }
        guard let i = tags.firstIndex(of: tag) else { return Theme.C.ink2 }
        return i % 2 == 0 ? Theme.C.accent : Theme.C.ink
    }

    /// Stable order of an entry field's values, as first met.
    static func order(_ values: [String?]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { $0 }.filter { seen.insert($0).inserted }
    }
}

/// A book key: `KeyStyle` with an optional slipping edge. Unseen is dashed.
struct BookKeyStyle: ButtonStyle {
    var unseen = false
    var edge: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        KeyStyle(unseen ? .unseen : .neutral, edge: edge).makeBody(configuration: configuration)
    }
}

/// The dark bar pinned above the tabs.
struct SpeedRoundBar: View {
    let title: String
    let trailing: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(trailing).foregroundStyle(Theme.C.accentOnInverse)
            }
            .font(Theme.F.label)
            .tracking(1)
            .foregroundStyle(Theme.C.onInverse)
            .padding(.horizontal, 14)
            .frame(height: 48)
        }
        .buttonStyle(KeyStyle(.inverse, perforated: true))
    }

    /// Bar, drop and padding: what the page keeps clear under its last row.
    static let footprint: CGFloat = 48 + Theme.M.drop + 2 * Theme.M.gapTight
}

/// Diagonal hatching: an unstarted chapter.
struct Hatch: View {
    var body: some View {
        Canvas { ctx, size in
            var x = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                ctx.stroke(p, with: .color(Theme.C.seam.opacity(0.8)), lineWidth: 1)
                x += 6
            }
        }
        .allowsHitTesting(false)
    }
}

/// The accent I-beam: where you are.
struct IBeam: View {
    var body: some View {
        Rectangle().fill(Theme.C.accent).frame(width: 3, height: 11)
    }
}

extension Chapter {
    /// The head as said: a pairs entry carries its preposition (warten auf).
    func fullHead(_ entry: Chapter.Entry) -> String {
        guard layout == .pairs, let group = entry.group, !group.isEmpty,
              !group.contains(" "), !entry.head.lowercased().contains(group.lowercased())
        else { return entry.head }
        return "\(entry.head) \(group)"
    }
}

/// The last attempts, oldest first, padded to eight.
struct Ticks: View {
    let recent: [Bool]

    var body: some View {
        HStack(spacing: 2) {
            let pad = max(0, 8 - recent.count)
            ForEach(0..<pad, id: \.self) { _ in
                Rectangle().strokeBorder(Theme.C.seam2, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5])).frame(width: 7, height: 14)
            }
            ForEach(Array(recent.suffix(8).enumerated()), id: \.offset) { _, ok in
                Rectangle().fill(ok ? Theme.C.good : Theme.C.bad).frame(width: 7, height: 14)
            }
        }
    }
}

extension EntryState {
    /// In the learner's words, for tags.
    var label: String {
        if slipping { return "SLIPPING" }
        switch standing {
        case .never:   return "NEVER USED"
        case .tried:   return "TRIED"
        case .holding: return "HOLDING"
        case .solid:   return "SOLID"
        }
    }

    var right: Int { recent.filter { $0 }.count }
}

/// `Tag`, tinted. Ink means plain.
struct BookTag: View {
    let text: String
    var colour: Color = Theme.C.ink

    var body: some View {
        Tag(text, .tinted(colour))
    }
}

/// The swipe back survives a hidden navigation bar.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
