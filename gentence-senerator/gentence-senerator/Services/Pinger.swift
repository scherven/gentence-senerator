import ActivityKit
import Foundation
import UserNotifications

/// Keeps the day's reminders in step with what is done: local notifications
/// for each slot (time sensitive, so they pass Focus), the Live Activity for
/// the slot running now, and the same plan on the worker, which starts each
/// slot's Live Activity by push when the app is not running.
@MainActor
final class Pinger {
    static let shared = Pinger()

    private var startToken: String?
    private var activityToken: String?
    private var last: [Pings.Fire]?
    private var soon: Task<Void, Never>?
    private var observing = false

    private static let prefix = "ping."

    /// Push-to-start and per-activity tokens, from launch on: iOS may start
    /// the app in the background just to hand one over.
    func observe() {
        guard !observing else { return }
        observing = true
        Task {
            for await data in Activity<PingAttributes>.pushToStartTokenUpdates {
                startToken = Self.hex(data)
                await upload((last ?? []).filter { $0.at > .now })
            }
        }
        Task {
            for await activity in Activity<PingAttributes>.activityUpdates {
                // A new slot's activity replaces the one before it.
                for old in Activity<PingAttributes>.activities where old.id != activity.id {
                    await old.end(nil, dismissalPolicy: .immediate)
                }
                Task {
                    for await data in activity.pushTokenUpdates {
                        activityToken = Self.hex(data)
                        await post("/pings/activity", ["token": Self.hex(data)])
                    }
                }
            }
        }
    }

    /// Coalesces the many small changes a session makes into one replan.
    func replanSoon(_ store: Store) {
        // Unit tests build stores by the hundred.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        soon?.cancel()
        soon = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            await replan(store)
        }
    }

    func replan(_ store: Store, now: Date = .now) async {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        let s = store.settings
        let fires = s.pingsOn
            ? Pings.plan(languages: s.languages, from: s.wakeFrom, to: s.wakeTo, now: now,
                         done: { store.done($0.mode, in: $0.language) },
                         body: { store.nextLine($0.mode, in: $0.language) },
                         talk: store.talkedToday ? nil : Pings.talkLanguage(s.languages, on: now))
            : []
        await activity(fires.first { $0.at <= now && now < $0.end })
        guard fires != last else { return }
        last = fires
        await notify(fires.filter { $0.at > now })
        await upload(fires.filter { $0.at > now })
    }

    // MARK: Notifications

    private func notify(_ fires: [Pings.Fire]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.hasPrefix(Self.prefix) })
        // A delivered reminder for something since done is stale.
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let keep = Set(fires.map(\.id))
        center.removeDeliveredNotifications(withIdentifiers:
            delivered.filter { $0.hasPrefix(Self.prefix) && !keep.contains($0) })

        for fire in fires {
            let content = UNMutableNotificationContent()
            content.title = fire.title
            if let body = fire.body { content.body = body }
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = "ping"
            content.userInfo = ["ping": [fire.items[0].language.rawValue, fire.items[0].mode.rawValue]]
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire.at)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: fire.id, content: content, trigger: trigger))
        }
    }

    // MARK: Live Activity

    nonisolated static func state(_ fire: Pings.Fire) -> PingAttributes.ContentState {
        let lead = fire.items.count > 1
            ? "\(fire.items[0].language.code)+\(fire.items.count - 1)"
            : fire.items[0].mode == .converse ? "talk" : fire.items[0].language.code
        return .init(title: fire.title, end: fire.end.timeIntervalSince1970, ticks: fire.ticks, lead: lead)
    }

    /// The slot running now, or none. Starting one needs the app in front;
    /// otherwise the worker's push will have started it.
    private func activity(_ fire: Pings.Fire?) async {
        let running = Activity<PingAttributes>.activities
        guard let fire else {
            for a in running { await a.end(nil, dismissalPolicy: .immediate) }
            return
        }
        let content = ActivityContent(state: Self.state(fire), staleDate: fire.end)
        if let newest = running.last {
            for a in running.dropLast() { await a.end(nil, dismissalPolicy: .immediate) }
            if newest.content.state != content.state { await newest.update(content) }
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: PingAttributes(), content: content, pushType: .token)
        }
    }

    // MARK: Worker

    /// The plan, for the worker's cron. Sent whole each time: it replaces the
    /// last one.
    private func upload(_ fires: [Pings.Fire]) async {
        guard let startToken, Worker.invite != nil else { return }
        let encoded: [[String: Any]] = fires.map { fire in
            let st = Self.state(fire)
            var alert: [String: Any] = ["title": fire.title]
            if let body = fire.body { alert["body"] = body }
            return ["at": fire.at.timeIntervalSince1970, "end": fire.end.timeIntervalSince1970,
                    "alert": alert,
                    "state": ["title": st.title, "end": st.end, "ticks": st.ticks, "lead": st.lead]]
        }
        await post("/pings", ["token": startToken, "sandbox": Sender.sandbox, "fires": encoded])
    }

    private func post(_ path: String, _ body: [String: Any]) async {
        var request = URLRequest(url: Worker.url(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        Worker.authorize(&request)
        request.timeoutInterval = 20
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // Offline: the local notifications still fire; the next replan resends.
        if (try? await URLSession.shared.data(for: request)) == nil { last = nil }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02.2hhx", $0) }.joined()
    }
}

extension Pings {
    /// Talk goes round the languages a day at a time.
    static func talkLanguage(_ languages: [Language], on day: Date) -> Language? {
        guard !languages.isEmpty else { return nil }
        let n = Calendar.current.ordinality(of: .day, in: .era, for: day) ?? 0
        return languages[n % languages.count]
    }
}

extension Store {
    /// Today's session in `mode` for any language, not just the one on screen.
    func todaySession(_ mode: Mode, in language: Language) -> Session? {
        let id = "\(Spend.key(.now))|\(language.rawValue)|\(mode.rawValue)"
        if let live = session, live.id == id { return live }
        if let held = holds[Store.holdKey(language, mode)]?.session, held.id == id { return held }
        return past.last { $0.id == id }
    }

    func done(_ mode: Mode, in language: Language) -> Bool {
        todaySession(mode, in: language)?.isComplete ?? false
    }

    var talkedToday: Bool {
        let day = Spend.key(.now)
        return past.contains { $0.mode == .converse && $0.id.hasPrefix(day) }
    }

    /// The next line the session will ask: an English sentence for
    /// translate, the message itself for reply.
    func nextLine(_ mode: Mode, in language: Language) -> String? {
        let prompt: Turn.Prompt?
        if let s = todaySession(mode, in: language), let planned = s.planned, planned.count > s.turns.count {
            prompt = planned[s.turns.count]
        } else {
            prompt = packDays.first { $0.language == language }?.prompts(mode).first
        }
        return mode == .reply ? prompt?.target ?? prompt?.english : prompt?.english
    }

    /// From a tapped reminder: that language, that mode.
    func openPing(_ pair: [String]) async {
        guard pair.count == 2,
              let language = Language(rawValue: pair[0]), let mode = Mode(rawValue: pair[1]),
              !quizOpen, phase == .idle || phase == .complete else { return }
        guard settings.languages.contains(language) else { return }
        switchLanguage(language)
        if mode != .converse { await begin(mode) }
    }
}
