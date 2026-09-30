import SwiftUI

// Shared components for "Typescript & Ledger". Tokens are in `Theme.swift`.
// Everything is square: hairlines, hard offset shadows, no radius, no blur.

// MARK: - Type helpers

extension View {
    /// CAPS mono label: Courier Prime bold 11, tracked. Values stay lowercase
    /// and use `Theme.F.meta` without this.
    func monoCaps(_ font: Font = Theme.F.label) -> some View {
        self.font(font).tracking(Theme.M.caps).textCase(.uppercase)
    }
}

// MARK: - Keys

/// A typewriter key: hairline border, hard offset shadow, sinks onto its
/// shadow when pressed. The one button look in the app.
struct KeyStyle: ButtonStyle {
    enum Variant: Equatable {
        /// Surface face, ink border, seam2 drop straight down.
        case neutral
        /// Accent face, onAccent label, accentDeep drop down-right.
        case primary
        /// Dark slip: inverse face, onInverse label.
        case inverse
        /// Quiz: the right answer.
        case right
        /// Quiz: the wrong pick, struck through.
        case wrong
        /// Quiz: picked, not yet marked.
        case chosen
        /// Spent or not in play: flush, no drop, ink3.
        case dim
        /// Never met: dashed seam2 outline at half strength. Still tappable.
        case unseen

        static let spent = Variant.dim
    }

    var variant: Variant = .neutral
    /// Replaces the border (and a neutral key's drop), e.g. `bad` for slipping.
    var edge: Color? = nil
    /// Replaces the face.
    var fill: Color? = nil
    /// Label fills the whole key, as quiz options do.
    var expand: Bool = false
    /// A disabled neutral / primary / inverse key draws as `.dim`.
    var dimsWhenDisabled: Bool = true
    /// Torn-off bottom edge, for inverse slips.
    var perforated: Bool = false

    init(_ variant: Variant = .neutral, edge: Color? = nil, fill: Color? = nil,
         expand: Bool = false, dimsWhenDisabled: Bool = true, perforated: Bool = false) {
        self.variant = variant
        self.edge = edge
        self.fill = fill
        self.expand = expand
        self.dimsWhenDisabled = dimsWhenDisabled
        self.perforated = perforated
    }

    func makeBody(configuration: Configuration) -> some View {
        KeyBody(style: self, label: configuration.label, pressed: configuration.isPressed)
    }

    private struct KeyBody<Label: View>: View {
        let style: KeyStyle
        let label: Label
        let pressed: Bool
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            let swap = !enabled && style.dimsWhenDisabled
                && [.neutral, .primary, .inverse].contains(style.variant)
            KeyFace(variant: swap ? .dim : style.variant, pressed: pressed,
                    edge: style.edge, fill: style.fill, expand: style.expand,
                    perforated: style.perforated) { label }
        }
    }
}

/// The drawing behind `KeyStyle`, also used for static slips and cards.
struct KeyFace<Content: View>: View {
    var variant: KeyStyle.Variant = .neutral
    var pressed = false
    var edge: Color? = nil
    var fill: Color? = nil
    var expand = false
    var perforated = false
    @ViewBuilder var content: Content

    private typealias V = KeyStyle.Variant
    private var d: CGFloat { Theme.M.drop }

    var body: some View {
        let look = self.look
        let dx: CGFloat = variant == .primary ? d : 0
        let sunk = pressed && look.drop != nil || variant == .dim
        content
            .strikethrough(variant == .wrong, color: Theme.C.bad)
            .foregroundStyle(look.ink)
            .frame(maxWidth: expand ? .infinity : nil, maxHeight: expand ? .infinity : nil)
            .background(look.face)
            .overlay {
                Rectangle().strokeBorder(look.border,
                                         style: StrokeStyle(lineWidth: Theme.M.hair,
                                                            dash: variant == .unseen ? [3, 2] : []))
            }
            .overlay(alignment: .bottom) {
                if perforated { Perforation(colour: look.ink.opacity(0.7)) }
            }
            .offset(x: sunk ? dx : 0, y: sunk ? d : 0)
            .background {
                if let drop = look.drop {
                    Rectangle().fill(drop).offset(x: dx, y: d).opacity(pressed ? 0 : 1)
                }
            }
            .padding(.bottom, d)
            .padding(.trailing, dx)
            .opacity(variant == .unseen ? (pressed ? 0.3 : 0.5) : 1)
            .contentShape(Rectangle())
    }

    private struct Look { var face: Color; var ink: Color; var border: Color; var drop: Color? }

    private var look: Look {
        let C = Theme.C.self
        var l: Look = switch variant {
        case .neutral: Look(face: C.surface, ink: C.ink, border: C.ink, drop: C.seam2)
        case .primary: Look(face: C.accent, ink: C.onAccent, border: C.accentDeep, drop: C.accentDeep)
        case .inverse: Look(face: C.inverse, ink: C.onInverse, border: C.inverseDeep, drop: C.inverseDeep)
        case .right:   Look(face: C.good, ink: C.onAccent, border: C.good, drop: C.ink.opacity(0.55))
        case .wrong:   Look(face: C.surface, ink: C.bad, border: C.bad, drop: C.bad)
        case .chosen:  Look(face: C.accent, ink: C.onAccent, border: C.accentDeep, drop: C.accentDeep)
        case .dim:     Look(face: C.raised, ink: C.ink3, border: C.seam2, drop: nil)
        case .unseen:  Look(face: .clear, ink: C.ink, border: C.seam2, drop: nil)
        }
        if let edge, variant != .unseen {
            l.border = edge
            if variant == .neutral { l.drop = edge }
        }
        if let fill { l.face = fill }
        return l
    }
}

/// A torn edge: a dashed line along the bottom of a slip.
struct Perforation: View {
    var colour: Color = Theme.C.onInverse
    var body: some View {
        Canvas { ctx, size in
            var x: CGFloat = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 4, height: size.height)), with: .color(colour))
                x += 8
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}

/// The full- or half-width action at the foot of a screen. 50pt, Courier
/// bold caps. Put two in an HStack for halves.
struct ActionKey: View {
    let title: String
    var variant: KeyStyle.Variant = .primary
    var enabled: Bool = true
    let action: () -> Void

    init(_ title: String, variant: KeyStyle.Variant = .primary, enabled: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.variant = variant
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Theme.F.mono(13, bold: true))
                .tracking(1.5)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity)
                .frame(height: 50)
        }
        .buttonStyle(KeyStyle(variant))
        .disabled(!enabled)
    }
}

/// Small square control for every secondary action.
struct TinyButton: View {
    let title: String
    var selected: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(Theme.F.label)
                .tracking(Theme.M.caps)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .foregroundStyle(selected ? Theme.C.onAccent : Theme.C.ink)
                .background(selected ? Theme.C.accent : Theme.C.surface)
                .overlay(Rectangle().strokeBorder(selected ? Theme.C.accentDeep : Theme.C.seam2,
                                                  lineWidth: Theme.M.hair))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
    }
}

/// A typed word that is a link: Courier, underlined, trailing ›.
struct TypedLink: View {
    let title: String
    var colour: Color = Theme.C.accent
    var chevron: Bool = true
    let action: () -> Void

    init(_ title: String, colour: Color = Theme.C.accent, chevron: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.colour = colour
        self.chevron = chevron
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            TypedLinkText(title: title, colour: colour, chevron: chevron)
        }
        .buttonStyle(PressDim())
    }
}

/// `TypedLink`'s look, for a `NavigationLink` label.
struct TypedLinkText: View {
    let title: String
    var colour: Color = Theme.C.accent
    var chevron: Bool = true

    var body: some View {
        (Text(title.uppercased()).underline(true, color: colour)
            + Text(chevron ? " ›" : ""))
            .font(Theme.F.meta)
            .tracking(Theme.M.caps)
            .foregroundStyle(colour)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
    }
}

/// Plain press feedback: fades while held.
struct PressDim: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

// MARK: - Legacy names

/// Full-width primary action. `ActionKey` under an older name.
struct MainButton: View {
    let title: String
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        ActionKey(title, variant: .primary, enabled: enabled, action: action)
    }
}

// MARK: - Surfaces

/// Hairline box on surface, with an optional consequence edge on the leading side.
struct Panel<Content: View>: View {
    var fill: Color = Theme.C.surface
    var edge: Color? = nil
    var padding: CGFloat = Theme.M.pad
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.M.gapTight) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(padding)
            .padding(.leading, edge == nil ? 0 : Theme.M.edge)
            .background(fill)
            // An overlay, not a sibling: a Rectangle in an HStack is greedy
            // vertically and stretches the panel to fill the screen.
            .overlay(alignment: .leading) {
                if let edge {
                    Rectangle().fill(edge).frame(width: Theme.M.edge)
                }
            }
            .overlay(Rectangle().strokeBorder(Theme.C.seam, lineWidth: Theme.M.hair))
    }
}

/// A sunk well: text inputs and anything typed into.
struct Inset<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.M.gapTight) { content }.inset()
    }
}

extension View {
    /// The `Inset` look on any view, e.g. a TextField.
    func inset(padding: CGFloat = Theme.M.pad) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.C.sunk)
            .overlay(Rectangle().strokeBorder(Theme.C.seam2, lineWidth: Theme.M.hair))
    }
}

/// A ruled index card: stock, a red rule under the heading line, faint blue
/// rules below it, and a hard shadow.
struct IndexCard<Content: View>: View {
    /// Distance of the red rule from the top. Nil: no heading line.
    var headRule: CGFloat? = 36
    /// Blue rule pitch. Nil: unruled.
    var pitch: CGFloat? = 24
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 12)
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .background {
                Canvas { ctx, size in
                    let top = headRule ?? 0
                    if let pitch {
                        var y = top + pitch
                        while y < size.height {
                            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 0.75)),
                                     with: .color(Theme.C.rule.opacity(0.3)))
                            y += pitch
                        }
                    }
                    if let headRule {
                        ctx.fill(Path(CGRect(x: 0, y: headRule, width: size.width, height: 1)),
                                 with: .color(Theme.C.margin))
                    }
                }
                .background(Theme.C.stock)
            }
            .overlay(Rectangle().strokeBorder(Theme.C.seam, lineWidth: Theme.M.hair))
            .background(Rectangle().fill(Theme.C.seam2).offset(x: 2, y: 2))
            .padding(.trailing, 2)
            .padding(.bottom, 2)
    }
}

/// A dark slip: inverse fill, hard drop, optional perforated bottom. Static;
/// as a button use `KeyStyle(.inverse, perforated: true)`.
struct Slip<Content: View>: View {
    var perforated = true
    @ViewBuilder var content: Content

    var body: some View {
        KeyFace(variant: .inverse, perforated: perforated) {
            VStack(alignment: .leading, spacing: Theme.M.gapTight) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Tags and headers

/// A CAPS mono tag in a hairline box.
struct Tag: View {
    enum Tone {
        /// ink2 text, seam2 hairline.
        case plain
        /// Coloured text, seam2 hairline.
        case tinted(Color)
        /// Filled: selection.
        case filled(Color)

        static var selected: Tone { .filled(Theme.C.accent) }
    }

    let text: String
    var tone: Tone = .plain

    init(_ text: String, _ tone: Tone = .plain) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        let (ink, fill, border): (Color, Color, Color) = switch tone {
        case .plain:            (Theme.C.ink2, .clear, Theme.C.seam2)
        case .tinted(let c):    (c, .clear, Theme.C.seam2)
        case .filled(let c):    (Theme.C.onAccent, c, c)
        }
        Text(text.uppercased())
            .font(Theme.F.label)
            .tracking(Theme.M.caps)
            .lineLimit(1)
            .foregroundStyle(ink)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(fill)
            .overlay(Rectangle().strokeBorder(border, lineWidth: Theme.M.hair))
    }
}

/// CAPS label with a double rule (1pt over 0.5pt) to the trailing edge. The
/// only section header in the app.
struct ModuleLabel: View {
    let text: String
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: Theme.M.gapTight) {
            Text(text.uppercased())
                .font(Theme.F.label)
                .tracking(1.1)
                .foregroundStyle(Theme.C.ink2)
                .lineLimit(1)
            DoubleRule()
            if let trailing {
                Text(trailing).font(Theme.F.meta).foregroundStyle(Theme.C.ink3)
            }
        }
    }
}

/// 1pt over 0.5pt, 2pt apart.
struct DoubleRule: View {
    var colour: Color = Theme.C.seam2
    var body: some View {
        VStack(spacing: 2) {
            Rectangle().fill(colour).frame(height: 1)
            Rectangle().fill(colour).frame(height: 0.5)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The row at the top of a pushed or full-screen page: a way out, the title,
/// a meta value. Attach with `.pageHeader(...)` so it stays put and nothing
/// scrolls under the status bar.
struct PageHeader<Trailing: View>: View {
    enum Lead {
        case none
        /// `‹ PARENT`: pops.
        case back(String)
        /// `✕ END` (or another word): ends the sitting.
        case end(String = "END")
    }

    var lead: Lead = .none
    var title: String = ""
    var centred: Bool = true
    /// Overrides dismiss for the leading control.
    var onLead: (() -> Void)? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            if centred {
                titleText.frame(maxWidth: 220)
            }
            HStack(spacing: Theme.M.gapTight) {
                leading
                if !centred { titleText; Spacer(minLength: 0) } else { Spacer(minLength: 0) }
                trailing
                    .font(Theme.F.meta)
                    .foregroundStyle(Theme.C.ink2)
            }
        }
        .frame(height: 44)
        .padding(.horizontal, Theme.M.gap)
    }

    private var titleText: some View {
        Text(title)
            .font(Theme.F.serif(17, bold: true))
            .foregroundStyle(Theme.C.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    @ViewBuilder private var leading: some View {
        switch lead {
        case .none:
            EmptyView()
        case .back(let parent):
            Button { (onLead ?? { dismiss() })() } label: {
                Text("‹ \(parent.uppercased())")
                    .font(Theme.F.meta).tracking(Theme.M.caps)
                    .foregroundStyle(Theme.C.accent)
                    .lineLimit(1)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
        case .end(let word):
            Button { (onLead ?? { dismiss() })() } label: {
                Text("✕ \(word.uppercased())")
                    .font(Theme.F.meta).tracking(Theme.M.caps)
                    .foregroundStyle(Theme.C.ink2)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
        }
    }
}

extension PageHeader where Trailing == Text {
    init(lead: Lead = .none, title: String = "", meta: String? = nil, centred: Bool = true,
         onLead: (() -> Void)? = nil) {
        self.init(lead: lead, title: title, centred: centred, onLead: onLead) {
            Text(meta ?? "")
        }
    }
}

extension View {
    /// Pins a `PageHeader` above this (scrolling) view on the ground colour,
    /// with a hairline under it. The ground runs up under the status bar.
    func pageHeader(_ lead: PageHeader<Text>.Lead = .none, title: String = "",
                    meta: String? = nil, centred: Bool = true,
                    onLead: (() -> Void)? = nil) -> some View {
        pageHeader(PageHeader(lead: lead, title: title, meta: meta, centred: centred, onLead: onLead))
    }

    func pageHeader<T: View>(_ header: PageHeader<T>) -> some View {
        safeAreaInset(edge: .top, spacing: 0) {
            header
                .background(Theme.C.ground.ignoresSafeArea(edges: .top))
                .overlay(alignment: .bottom) {
                    Rectangle().fill(Theme.C.seam).frame(height: Theme.M.hair)
                }
        }
    }
}

// MARK: - State of an entry

/// Where something stands in the record, as one of five cells.
enum LedgerState: CaseIterable, Hashable {
    case never, tried, holding, solid, slipping

    init(_ standing: DayPlan.Standing) {
        switch standing {
        case .never:   self = .never
        case .tried:   self = .tried
        case .holding: self = .holding
        case .solid:   self = .solid
        }
    }

    init(_ state: EntryState) {
        self = state.slipping ? .slipping : LedgerState(state.standing)
    }

    /// Nil for never: drawn as a dashed outline instead.
    var fill: Color? {
        switch self {
        case .never:    return nil
        case .tried:    return Theme.C.good.opacity(0.30)
        case .holding:  return Theme.C.good.opacity(0.65)
        case .solid:    return Theme.C.good
        case .slipping: return Theme.C.bad
        }
    }

    var name: String {
        switch self {
        case .never:    return "NEVER"
        case .tried:    return "TRIED"
        case .holding:  return "HOLDING"
        case .solid:    return "SOLID"
        case .slipping: return "SLIPPING"
        }
    }
}

/// One square per entry.
struct StateCell: View {
    let state: LedgerState
    var size: CGFloat = 11

    init(_ state: LedgerState, size: CGFloat = 11) {
        self.state = state
        self.size = size
    }

    init(state: EntryState, size: CGFloat = 11) {
        self.init(LedgerState(state), size: size)
    }

    var body: some View {
        Group {
            if let fill = state.fill {
                Rectangle().fill(fill)
            } else {
                Rectangle().strokeBorder(Theme.C.seam2,
                                         style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
            }
        }
        .frame(width: size, height: size)
    }
}

/// The one legend for state cells, on one line. Counts optional.
struct StateLegend: View {
    var states: [LedgerState] = LedgerState.allCases
    var counts: [LedgerState: Int]? = nil

    var body: some View {
        HStack(spacing: 10) {
            ForEach(states, id: \.self) { s in
                HStack(spacing: 4) {
                    StateCell(s, size: 8)
                    Text(counts.map { "\(s.name) \($0[s] ?? 0)" } ?? s.name)
                }
            }
        }
        .font(Theme.F.mono(10.5))
        .tracking(0.4)
        .foregroundStyle(Theme.C.ink2)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

// MARK: - Marks

/// A rubber stamp: rotated, double-ruled, Courier bold. One per screen.
struct Stamp: View {
    let text: String
    var colour: Color
    var size: CGFloat = 26

    init(_ text: String, colour: Color, size: CGFloat = 26) {
        self.text = text
        self.colour = colour
        self.size = size
    }

    /// A 0–100 score, coloured by band.
    init(score: Int, size: CGFloat = 26) {
        self.init("\(score)", colour: Theme.band(score), size: size)
    }

    var body: some View {
        Text(text.uppercased())
            .font(Theme.F.mono(size, bold: true))
            .foregroundStyle(colour)
            .lineLimit(1)
            .padding(.horizontal, size * 0.45)
            .padding(.vertical, size * 0.12)
            .overlay(Rectangle().strokeBorder(colour, lineWidth: 0.75).padding(3))
            .overlay(Rectangle().strokeBorder(colour, lineWidth: 2))
            .padding(3)
            .mask {
                Image("Speckle").resizable(resizingMode: .tile)
            }
            .rotationEffect(.degrees(-2.5))
            .accessibilityElement(children: .combine)
    }
}

/// A small filled number: marks a span and names its finding.
struct NumberTag: View {
    let number: Int
    var colour: Color

    var body: some View {
        Text("\(number)")
            .font(Theme.F.mono(10, bold: true))
            .foregroundStyle(Theme.C.surface)
            .padding(.horizontal, 3)
            .background(colour)
    }
}

/// A sentence with spans underlined (2pt, verdict colour), each followed by a
/// small filled number. Wraps like text.
struct SpanMark: View {
    struct Mark {
        /// Character offsets into the text.
        var range: Range<Int>
        var colour: Color
        var number: Int?

        init(_ range: Range<Int>, colour: Color, number: Int? = nil) {
            self.range = range
            self.colour = colour
            self.number = number
        }

        /// The first occurrence of `span` in `text`, if any.
        init?(_ span: String, in text: String, colour: Color, number: Int? = nil) {
            guard !span.isEmpty, let r = text.range(of: span) else { return nil }
            let start = text.distance(from: text.startIndex, to: r.lowerBound)
            self.init(start..<(start + span.count), colour: colour, number: number)
        }
    }

    let text: String
    let marks: [Mark]
    var font: Font = Theme.F.target
    var colour: Color = Theme.C.ink

    init(_ text: String, marks: [Mark], font: Font = Theme.F.target, colour: Color = Theme.C.ink) {
        self.text = text
        self.marks = marks
        self.font = font
        self.colour = colour
    }

    var body: some View {
        composed
            .font(font)
            .foregroundStyle(colour)
            .lineSpacing(6)
            .textRenderer(MarkRenderer())
            .fixedSize(horizontal: false, vertical: true)
    }

    private var composed: Text {
        let chars = Array(text)
        let sorted = marks
            .map { Mark(max(0, $0.range.lowerBound)..<min(chars.count, $0.range.upperBound),
                        colour: $0.colour, number: $0.number) }
            .filter { !$0.range.isEmpty }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
        var out = Text("")
        var at = 0
        for mark in sorted where mark.range.lowerBound >= at {
            out = out + Text(String(chars[at..<mark.range.lowerBound]))
            out = out + Text(String(chars[mark.range]))
                .customAttribute(Underline(colour: mark.colour))
            if let n = mark.number {
                out = out + Text("\u{2009}")
                    + Text(" \(n) ")
                        .font(Theme.F.mono(10, bold: true))
                        .foregroundColor(Theme.C.surface)
                        .baselineOffset(7)
                        .customAttribute(Filled(colour: mark.colour))
            }
            at = mark.range.upperBound
        }
        if at < chars.count { out = out + Text(String(chars[at...])) }
        return out
    }

    fileprivate struct Underline: TextAttribute { let colour: Color }
    fileprivate struct Filled: TextAttribute { let colour: Color }

    private struct MarkRenderer: TextRenderer {
        func draw(layout: Text.Layout, in ctx: inout GraphicsContext) {
            for line in layout {
                for run in line {
                    let box = run.typographicBounds.rect
                    if let u = run[Underline.self] {
                        ctx.fill(Path(CGRect(x: box.minX, y: run.typographicBounds.origin.y + 3,
                                             width: box.width, height: 2)),
                                 with: .color(u.colour))
                    }
                    if let f = run[Filled.self] {
                        ctx.fill(Path(box.insetBy(dx: 0, dy: 1)), with: .color(f.colour))
                    }
                    ctx.draw(run)
                }
            }
        }
    }
}

/// One row of a ledger: consequence edge | account (CAPS mono, verdict
/// colour) | red double margin | the entry. Ruled underneath.
struct LedgerRow<Entry: View, Trailing: View>: View {
    let account: String
    var colour: Color = Theme.C.ink2
    var number: Int? = nil
    /// The 3pt leading edge. Nil: none.
    var edge: Color? = nil
    var accountWidth: CGFloat = 88
    var ruled: Bool = true
    @ViewBuilder var entry: Entry
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let number { NumberTag(number: number, colour: colour) }
                Text(account.uppercased())
                    .font(Theme.F.label)
                    .tracking(0.6)
                    .foregroundStyle(colour)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
            .frame(width: accountWidth, alignment: .leading)

            HStack(spacing: 2.5) {
                Rectangle().fill(Theme.C.margin).frame(width: 0.75)
                Rectangle().fill(Theme.C.margin).frame(width: 0.75)
            }
            .frame(maxHeight: .infinity)

            entry
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, edge == nil ? 0 : Theme.M.edge)
        .overlay(alignment: .leading) {
            if let edge { Rectangle().fill(edge).frame(width: Theme.M.edge) }
        }
        .overlay(alignment: .bottom) {
            if ruled { Rectangle().fill(Theme.C.rule.opacity(0.45)).frame(height: Theme.M.hair) }
        }
    }
}

extension LedgerRow where Trailing == EmptyView {
    init(account: String, colour: Color = Theme.C.ink2, number: Int? = nil, edge: Color? = nil,
         accountWidth: CGFloat = 88, ruled: Bool = true, @ViewBuilder entry: () -> Entry) {
        self.init(account: account, colour: colour, number: number, edge: edge,
                  accountWidth: accountWidth, ruled: ruled, entry: entry) { EmptyView() }
    }
}

/// The page ledger rows sit on: surface, hairline.
struct LedgerSheet<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.C.surface)
            .overlay(Rectangle().strokeBorder(Theme.C.seam, lineWidth: Theme.M.hair))
    }
}

// MARK: - Square controls

/// − value +, in TinyButtons.
struct SquareStepper<Label: View>: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    @ViewBuilder var label: Label

    init(value: Binding<Int>, in range: ClosedRange<Int>, @ViewBuilder label: () -> Label) {
        _value = value
        self.range = range
        self.label = label()
    }

    var body: some View {
        HStack(spacing: Theme.M.gapTight) {
            label.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 0) {
                step("−", by: -1)
                Text("\(value)")
                    .font(Theme.F.mono(13, bold: true))
                    .foregroundStyle(Theme.C.ink)
                    .frame(minWidth: 34)
                step("+", by: 1)
            }
        }
    }

    private func step(_ glyph: String, by delta: Int) -> some View {
        let next = value + delta
        let ok = range.contains(next)
        return Button { if ok { value = next } } label: {
            Text(glyph)
                .font(Theme.F.mono(15, bold: true))
                .foregroundStyle(ok ? Theme.C.ink : Theme.C.ink3)
                .frame(width: 36, height: 32)
                .background(ok ? Theme.C.surface : Theme.C.raised)
                .overlay(Rectangle().strokeBorder(Theme.C.seam2, lineWidth: Theme.M.hair))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .disabled(!ok)
        .accessibilityLabel(delta < 0 ? "Decrease" : "Increase")
    }
}

/// ON | OFF, the live half filled.
struct SquareToggle<Label: View>: View {
    @Binding var isOn: Bool
    @ViewBuilder var label: Label

    init(isOn: Binding<Bool>, @ViewBuilder label: () -> Label) {
        _isOn = isOn
        self.label = label()
    }

    var body: some View {
        HStack(spacing: Theme.M.gapTight) {
            label.frame(maxWidth: .infinity, alignment: .leading)
            Button { isOn.toggle() } label: {
                HStack(spacing: 0) {
                    half("ON", live: isOn)
                    half("OFF", live: !isOn)
                }
                .overlay(Rectangle().strokeBorder(Theme.C.ink, lineWidth: Theme.M.hair))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressDim())
            .accessibilityValue(isOn ? "On" : "Off")
        }
    }

    private func half(_ word: String, live: Bool) -> some View {
        Text(word)
            .font(Theme.F.label).tracking(Theme.M.caps)
            .foregroundStyle(live ? Theme.C.onInverse : Theme.C.ink3)
            .frame(width: 40, height: 28)
            .background(live ? Theme.C.inverse : Theme.C.surface)
    }
}

/// A flat bar with a hairline.
struct SquareProgress: View {
    let value: Double
    var total: Double = 1
    var tint: Color = Theme.C.ink
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            Rectangle().fill(tint)
                .frame(width: g.size.width * CGFloat(min(max(value / max(total, .ulpOfOne), 0), 1)))
        }
        .frame(height: height)
        .background(Theme.C.raised)
        .overlay(Rectangle().strokeBorder(Theme.C.seam2, lineWidth: Theme.M.hair))
    }
}

/// A typed ellipsis that cycles: the spinner.
struct Ticker: View {
    var text: String? = nil
    var colour: Color = Theme.C.ink2

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.35)) { t in
            let n = Int(t.date.timeIntervalSinceReferenceDate / 0.35) % 4
            HStack(spacing: 0) {
                if let text { Text(text.uppercased()).tracking(Theme.M.caps) }
                Text(String(repeating: ".", count: n) + String(repeating: " ", count: 3 - n))
            }
            .font(Theme.F.meta)
            .foregroundStyle(colour)
        }
        .accessibilityLabel(text ?? "Working")
    }
}

// MARK: - Paper

/// The static paper grain over the whole window.
struct Grain: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Image("Grain")
            .resizable(resizingMode: .tile)
            .blendMode(scheme == .dark ? .screen : .multiply)
            .opacity(scheme == .dark ? 0.045 : 0.07)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Ground behind, grain over. Once per window or presented screen.
    func paper() -> some View {
        self
            .background(Theme.C.ground.ignoresSafeArea())
            .overlay { Grain() }
    }
}
