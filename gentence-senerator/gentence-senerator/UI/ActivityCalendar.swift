import SwiftUI

/// One month. Dark: translate, produce and a quiz all done. Light: some.
struct ActivityCalendar: View {
    let store: Store
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)!.start

    private var cal: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(month.formatted(.dateTime.month(.abbreviated).year()).uppercased())
                    .font(Theme.F.label).tracking(1)
                Spacer()
                step("‹", by: -1)
                step("›", by: 1).disabled(isCurrentMonth).opacity(isCurrentMonth ? 0.3 : 1)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                ForEach(Array(weekdays.enumerated()), id: \.offset) { _, d in
                    Text(d).font(Theme.F.label).foregroundStyle(Theme.C.ink3)
                }
                ForEach(0..<leading, id: \.self) { _ in Color.clear.aspectRatio(1, contentMode: .fit) }
                ForEach(days, id: \.self) { day in cell(day) }
            }
        }
        .padding(Theme.M.padTight)
        .background(Theme.C.surface)
        .overlay(Rectangle().stroke(Theme.C.seam, lineWidth: Theme.M.hair))
    }

    private func cell(_ day: Date) -> some View {
        let shade = ActivityLog.shade(store.activity(on: day))
        let future = day > .now
        return ZStack {
            Rectangle().fill(fill(shade))
            Text("\(cal.component(.day, from: day))")
                .font(Theme.F.meta)
                .foregroundStyle(shade == .all ? Theme.C.onAccent : future ? Theme.C.ink3 : Theme.C.ink2)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(Rectangle().stroke(cal.isDateInToday(day) ? Theme.C.accent : Theme.C.seam,
                                    lineWidth: cal.isDateInToday(day) ? 1.5 : Theme.M.hair))
        .opacity(future ? 0.5 : 1)
    }

    private func fill(_ shade: ActivityLog.Shade) -> Color {
        switch shade {
        case .all:  return Theme.C.good
        case .some: return Theme.C.good.opacity(0.35)
        case .none: return Theme.C.ground
        }
    }

    private func step(_ label: String, by months: Int) -> some View {
        Button {
            month = cal.date(byAdding: .month, value: months, to: month) ?? month
        } label: {
            Text(label).font(Theme.F.meta).frame(width: 32, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(months < 0 ? "Previous month" : "Next month")
    }

    private var isCurrentMonth: Bool { cal.isDate(month, equalTo: .now, toGranularity: .month) }

    private var days: [Date] {
        guard let range = cal.range(of: .day, in: .month, for: month) else { return [] }
        return range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }
    }

    /// Blank cells before the 1st, Monday first.
    private var leading: Int {
        (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
    }

    private var weekdays: [String] { ["M", "T", "W", "T", "F", "S", "S"] }
}
