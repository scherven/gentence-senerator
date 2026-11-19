import ActivityKit
import SwiftUI
import WidgetKit

@main
struct PingWidgets: WidgetBundle {
    var body: some Widget { PingLive() }
}

/// The running slot: what is owed, and the time left until the next one.
struct PingLive: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PingAttributes.self) { context in
            Slab(state: context.state)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .activityBackgroundTint(Ink.ground)
                .activitySystemActionForegroundColor(Ink.text)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    Slab(state: context.state).padding(.horizontal, 8).padding(.bottom, 6)
                }
            } compactLeading: {
                Text(context.state.lead).font(Ink.mono(14)).foregroundStyle(Ink.text)
            } compactTrailing: {
                Clock(end: context.state.endDate).font(Ink.mono(14))
                    .frame(maxWidth: 56)
            } minimal: {
                Text(context.state.lead).font(Ink.mono(12)).foregroundStyle(Ink.text)
            }
        }
    }
}

private struct Slab: View {
    let state: PingAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(state.title.uppercased())
                    .font(Ink.mono(13)).tracking(1.5)
                    .foregroundStyle(Ink.text)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 12)
                Clock(end: state.endDate).font(Ink.mono(34))
            }
            HStack(spacing: 4) {
                ForEach(Array(state.ticks.enumerated()), id: \.offset) { _, tick in
                    Rectangle().fill(tick == 0 ? Ink.text : tick == 1 ? Ink.accent : Ink.empty)
                        .frame(height: 3)
                }
            }
        }
    }
}

/// Counts itself down; no updates needed.
private struct Clock: View {
    let end: Date

    var body: some View {
        Text(timerInterval: Date.now...max(end, .now), countsDown: true)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .foregroundStyle(Ink.accent)
    }
}

private enum Ink {
    static let ground = Color(red: 0x23 / 255, green: 0x25 / 255, blue: 0x1F / 255)
    static let text   = Color(red: 0xE3 / 255, green: 0xE1 / 255, blue: 0xD5 / 255)
    static let accent = Color(red: 0xD4 / 255, green: 0x70 / 255, blue: 0x3C / 255)
    static let empty  = Color(red: 0x4A / 255, green: 0x4C / 255, blue: 0x45 / 255)

    static func mono(_ size: CGFloat) -> Font { .custom("CourierPrime-Bold", fixedSize: size) }
}
