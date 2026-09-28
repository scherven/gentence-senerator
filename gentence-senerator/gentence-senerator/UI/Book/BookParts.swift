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
}

enum BookColour {
    /// The second side of a split and the second case of a pair: DAT, ÊTRE.
    static let cool = Theme.C.dyn(0x3D5A80, 0x7F9CC4)
    /// The accent on an `ink` fill.
    static let onInk = Theme.C.dyn(0xD4703C, 0xA8481A)

    /// Nil for never: drawn as a dashed outline instead of a fill.
    static func fill(_ state: EntryState) -> Color? {
        if state.slipping { return Theme.C.bad }
        if state.standing == .never { return nil }
        return Theme.colour(for: state.standing)
    }

    /// The first tag seen takes the accent, the second the cool side.
    static func tag(_ tag: String?, among tags: [String]) -> Color {
        guard let tag else { return Theme.C.ink2 }
        switch tag.uppercased() {
        case "AKK", "AVOIR": return Theme.C.accent
        case "DAT", "ÊTRE", "ETRE": return cool
        default: break
        }
        guard let i = tags.firstIndex(of: tag) else { return Theme.C.ink2 }
        return i % 2 == 0 ? Theme.C.accent : cool
    }

    /// Stable order of an entry field's values, as first met.
    static func order(_ values: [String?]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { $0 }.filter { seen.insert($0).inserted }
    }
}

/// A key: hairline, hard bottom shadow, sinks when pressed. Unseen is a
/// dashed, faded outline with no shadow — still tappable.
struct BookKeyStyle: ButtonStyle {
    var unseen = false
    var edge: Color = Theme.C.seam2
    var fill: Color = Theme.C.surface
    var drop: CGFloat = 2

    func makeBody(configuration: Configuration) -> some View {
        let down = configuration.isPressed && !unseen
        configuration.label
            .background(unseen ? Color.clear : fill)
            .overlay(
                Rectangle().strokeBorder(unseen ? Theme.C.seam2 : edge,
                                         style: StrokeStyle(lineWidth: Theme.M.hair,
                                                            dash: unseen ? [3, 2] : []))
            )
            .offset(y: down ? drop : 0)
            .background(alignment: .bottom) {
                if !unseen {
                    Rectangle().fill(edge).offset(y: drop).opacity(down ? 0 : 1)
                }
            }
            .padding(.bottom, unseen ? 0 : drop)
            .opacity(unseen ? (configuration.isPressed ? 0.3 : 0.5) : 1)
            .contentShape(Rectangle())
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
                Text(trailing).foregroundStyle(Theme.C.ink3)
            }
            .font(Theme.F.meta.weight(.medium))
            .tracking(1)
            .foregroundStyle(Theme.C.surface)
            .padding(.horizontal, 14)
            .frame(height: 48)
        }
        .buttonStyle(BookKeyStyle(edge: .black, fill: Theme.C.ink, drop: 3))
    }
}

/// ‹ BOOK, the name, met/total.
struct BookPageHeader: View {
    let back: String
    let title: String
    var count: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { dismiss() } label: {
                Text("‹ \(back.uppercased())")
                    .font(Theme.F.meta)
                    .foregroundStyle(Theme.C.accent)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !title.isEmpty { HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.C.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let count {
                    Text(count).font(Theme.F.meta).foregroundStyle(Theme.C.ink2)
                }
            } }
        }
    }
}

/// One small square per entry, coloured by where it stands.
struct StateCell: View {
    let state: EntryState
    var size: CGFloat = 11

    var body: some View {
        Group {
            if let fill = BookColour.fill(state) {
                Rectangle().fill(fill)
            } else {
                Rectangle().strokeBorder(Theme.C.seam2,
                                         style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The last attempts, oldest first, padded to eight.
struct Ticks: View {
    let recent: [Bool]

    var body: some View {
        HStack(spacing: 2) {
            let pad = max(0, 8 - recent.count)
            ForEach(0..<pad, id: \.self) { _ in
                Rectangle().strokeBorder(Theme.C.seam, lineWidth: 1).frame(width: 7, height: 14)
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

/// A mono tag in a hairline box.
struct BookTag: View {
    let text: String
    var colour: Color = Theme.C.ink

    var body: some View {
        Text(text)
            .font(Theme.F.label)
            .foregroundStyle(colour)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .overlay(Rectangle().stroke(colour == Theme.C.ink ? Theme.C.seam2 : colour,
                                        lineWidth: Theme.M.hair))
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
