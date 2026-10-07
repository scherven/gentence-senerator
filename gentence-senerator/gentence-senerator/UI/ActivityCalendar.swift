import SwiftUI

/// One month, an ink pad. Dark: translate, produce and a quiz all done. Light:
/// some. Three ticks per cell say which, in that order; the day's average
/// score sits top right. Averages for the week, month and all time below.
struct ActivityCalendar: View {
    let store: Store
    /// Days ("yyyy-MM-dd") that have an archive block to scroll to.
    var targets: Set<String> = []
    var onPick: (String) -> Void = { _ in }
    @State private var month = Calendar.current.dateInterval(of: .month, for: .now)!.start

    private var cal: Calendar {
        var c = Calendar.current
        c.firstWeekday = 2
        return c
    }

    private static let cell: CGFloat = 48

    var body: some View {
        Panel(padding: 10) {
            HStack(spacing: 0) {
                Text(month.formatted(.dateTime.month(.abbreviated).year()).uppercased())
                    .font(Theme.F.mono(12, bold: true)).tracking(1)
                    .foregroundStyle(Theme.C.ink)
                    .padding(.trailing, Theme.M.gapTight)
                DoubleRule()
                step("‹", by: -1)
                step("›", by: 1).disabled(isCurrentMonth)
            }
            // Not lazy: a LazyVGrid under-reports its height inside the panel.
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(Array(weekdays.enumerated()), id: \.offset) { _, d in
                        Text(d).font(Theme.F.mono(10)).foregroundStyle(Theme.C.ink3)
                            .frame(maxWidth: .infinity)
                    }
                }
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    GridRow {
                        ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                            if let day { cell(day) } else { Color.clear.frame(height: Self.cell) }
                        }
                    }
                }
            }
            averages
        }
    }

    /// Last seven days, the month on show, everything.
    private var averages: some View {
        let weekStart = cal.date(byAdding: .day, value: -6, to: .now) ?? .now
        let monthEnd = cal.date(byAdding: DateComponents(month: 1, day: -1), to: month) ?? month
        return HStack(spacing: Theme.M.gap) {
            average("7 days", store.averageScore(from: weekStart))
            average(month.formatted(.dateTime.month(.abbreviated)),
                    store.averageScore(from: month, through: monthEnd))
            average("All", store.averageScore())
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private func average(_ label: String, _ score: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label.uppercased()).font(Theme.F.label).tracking(Theme.M.caps)
                .foregroundStyle(Theme.C.ink3)
            Text(score.map(String.init) ?? "—").font(Theme.F.mono(15, bold: true))
                .foregroundStyle(score.map(Theme.band) ?? Theme.C.ink3)
        }
    }

    /// Monday-first rows of seven, blank-padded at both ends.
    private var weeks: [[Date?]] {
        var slots: [Date?] = Array(repeating: nil, count: leading) + days.map { $0 }
        while slots.count % 7 != 0 { slots.append(nil) }
        return stride(from: 0, to: slots.count, by: 7).map { Array(slots[$0..<$0 + 7]) }
    }

    @ViewBuilder
    private func cell(_ day: Date) -> some View {
        let key = Spend.key(day)
        if targets.contains(key) {
            Button { onPick(key) } label: { face(day) }
                .buttonStyle(PressDim())
        } else {
            face(day)
        }
    }

    private func face(_ day: Date) -> some View {
        let marks = store.activity(on: day)
        let shade = ActivityLog.shade(marks)
        let future = cal.startOfDay(for: day) > .now
        let today = cal.isDateInToday(day)
        return Rectangle().fill(fill(shade))
            .frame(height: Self.cell)
            .overlay(alignment: .topLeading) {
                Text("\(cal.component(.day, from: day))")
                    .font(Theme.F.mono(11))
                    .foregroundStyle(shade == .all ? Theme.C.ink : Theme.C.ink2)
                    .padding(.leading, 4).padding(.top, 2)
            }
            .overlay(alignment: .topTrailing) {
                if let score = store.averageScore(from: day, through: day) {
                    Text("\(score)")
                        .font(Theme.F.mono(10, bold: true))
                        .foregroundStyle(Theme.band(score))
                        .padding(.trailing, 4).padding(.top, 3)
                }
            }
            .overlay(alignment: .bottom) {
                if !marks.isEmpty { ticks(marks) }
            }
            .overlay {
                if today {
                    Rectangle().strokeBorder(Theme.C.accent, lineWidth: 1.5)
                    Rectangle().strokeBorder(Theme.C.accent, lineWidth: 0.75).padding(3)
                } else {
                    Rectangle().strokeBorder(future ? Theme.C.seam2 : Theme.C.seam,
                                             style: StrokeStyle(lineWidth: Theme.M.hair,
                                                                dash: future ? [3, 2] : []))
                }
            }
            .opacity(future ? 0.5 : 1)
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibility(day, marks))
    }

    /// Translate · produce · quiz. Filled when done, dashed when not.
    private func ticks(_ marks: Set<ActivityLog.Mark>) -> some View {
        HStack(spacing: 2) {
            ForEach(Array(ActivityLog.ticks(marks).enumerated()), id: \.offset) { _, on in
                if on {
                    Rectangle().fill(Theme.C.ink)
                } else {
                    Rectangle().strokeBorder(Theme.C.seam2,
                                             style: StrokeStyle(lineWidth: Theme.M.hair, dash: [2, 1.5]))
                }
            }
        }
        .frame(height: 4)
        .padding(.horizontal, 4)
        .padding(.bottom, 4)
    }

    private func fill(_ shade: ActivityLog.Shade) -> Color {
        switch shade {
        case .all:  return Theme.C.good.opacity(0.42)
        case .some: return Theme.C.good.opacity(0.22)
        case .none: return .clear
        }
    }

    private func accessibility(_ day: Date, _ marks: Set<ActivityLog.Mark>) -> String {
        let date = day.formatted(.dateTime.month(.wide).day())
        let done = ActivityLog.Mark.allCases.filter(marks.contains).map(\.rawValue)
        return done.isEmpty ? date : "\(date): \(done.joined(separator: ", "))"
    }

    private func step(_ label: String, by months: Int) -> some View {
        Button {
            month = cal.date(byAdding: .month, value: months, to: month) ?? month
        } label: {
            Text(label).font(Theme.F.mono(15, bold: true))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressDim())
        .foregroundStyle(months > 0 && isCurrentMonth ? Theme.C.seam2 : Theme.C.accent)
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
