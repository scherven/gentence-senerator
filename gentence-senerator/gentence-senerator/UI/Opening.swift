import SwiftUI

/// Cold launch only: the app icon, full screen. The cursor blinks twice, the
/// key presses down onto its shadow, then grows into the page Today is drawn on. Proportions are the icon's
/// (tools/make_icon.py), so the first frame is the icon the learner tapped.
struct Opening: View {
    let done: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cursorOn = true
    @State private var pressed = false
    @State private var expanded = false
    @State private var fading = false

    /// The icon's own colours, in both appearances: this is the icon.
    private static let rust = Color(red: 0xA8 / 255, green: 0x48 / 255, blue: 0x1A / 255)
    private static let rustDeep = Color(red: 0x6E / 255, green: 0x2C / 255, blue: 0x0C / 255)
    private static let ink = Color(red: 0x23 / 255, green: 0x25 / 255, blue: 0x1F / 255)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // Face 594 of 1024, shadow pushed 123 of 1024 down and right.
            let face = w * 0.46
            let drop = face * 123 / 594
            let x = (w - face - drop) / 2
            let y = (h - face - drop) / 2

            ZStack(alignment: .topLeading) {
                Self.rust
                Self.rustDeep
                    .frame(width: face, height: face)
                    .offset(x: expanded ? x : x + drop, y: expanded ? y : y + drop)
                    .opacity(expanded ? 0 : 1)
                // Pressed, the face sits on its shadow, as a key does.
                let fx = pressed ? x + drop : x
                let fy = pressed ? y + drop : y
                Theme.C.ground
                    .frame(width: expanded ? w : face, height: expanded ? h : face)
                    .offset(x: expanded ? 0 : fx, y: expanded ? 0 : fy)
                cursor(face: face)
                    .offset(x: fx, y: fy)
                    .opacity(cursorOn ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .opacity(fading ? 0 : 1)
        .contentShape(Rectangle())
        .onTapGesture { done() }
        .accessibilityHidden(true)
        .task { await play() }
    }

    /// The icon's pixel I-beam: a one-unit stem, caps set one step out.
    private func cursor(face: CGFloat) -> some View {
        let u = face * 34 / 594
        let cx = face * 194 / 594
        let top = face * 112 / 594
        return ZStack(alignment: .topLeading) {
            Rectangle().frame(width: u, height: 9 * u).offset(x: cx - u / 2, y: top + u)
            ForEach([top, top + 10 * u], id: \.self) { y in
                Rectangle().frame(width: 2 * u, height: u).offset(x: cx - u / 2 - 2 * u, y: y)
                Rectangle().frame(width: 2 * u, height: u).offset(x: cx + u / 2, y: y)
            }
        }
        .foregroundStyle(Self.ink)
        .frame(width: face, height: face, alignment: .topLeading)
    }

    private func play() async {
        if reduceMotion {
            withAnimation(.easeOut(duration: 0.25)) { fading = true }
            try? await Task.sleep(for: .milliseconds(250))
            return done()
        }
        // Two quick blinks, a beat, then the press runs straight into the
        // expand.
        for _ in 0..<2 {
            try? await Task.sleep(for: .milliseconds(180))
            cursorOn = false
            try? await Task.sleep(for: .milliseconds(120))
            cursorOn = true
        }
        try? await Task.sleep(for: .milliseconds(350))
        withAnimation(.easeIn(duration: 0.12)) { pressed = true }
        try? await Task.sleep(for: .milliseconds(120))
        cursorOn = false
        withAnimation(.timingCurve(0.3, 0.1, 0.2, 1, duration: 0.7)) { expanded = true }
        try? await Task.sleep(for: .milliseconds(720))
        withAnimation(.easeOut(duration: 0.35)) { fading = true }
        try? await Task.sleep(for: .milliseconds(360))
        done()
    }
}
