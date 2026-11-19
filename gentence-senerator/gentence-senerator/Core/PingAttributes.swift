import ActivityKit
import Foundation

/// The reminder's Live Activity. Built into the app and the widget extension;
/// the worker's push-to-start names it as `attributes-type`, so the type name
/// and the field names are part of that payload.
struct PingAttributes: ActivityAttributes {
    /// Nothing fixed: a rolled-in slot changes everything as it is done.
    var day: String = ""

    struct ContentState: Codable, Hashable {
        var title: String
        /// Seconds since 1970: what the worker sends, without a date strategy.
        var end: Double
        /// One per slot: 0 done, 1 owed, 2 later.
        var ticks: [Int]
        /// The Dynamic Island's short form: "fr", or "fr+1".
        var lead: String

        var endDate: Date { Date(timeIntervalSince1970: end) }
    }
}
