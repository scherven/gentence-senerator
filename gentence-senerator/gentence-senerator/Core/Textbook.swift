import Foundation

/// One reference book per language: the curriculum, everything the learner has
/// been noted on, everything a tutor answer pointed them at, and what they
/// pinned. Assembled on read from records that already exist — the only new
/// thing stored is `Suggestion`, because ask answers are not otherwise kept.
///
/// Grouped by `AtomKind`, the same taxonomy findings and points already carry,
/// so a finding and the point it belongs to land in the same section.
enum Textbook {

    enum Origin: String, Codable, Hashable {
        case kept, noted, suggested, curriculum
    }

    enum Scope: Hashable {
        /// Pinned, noted and suggested.
        case mine
        /// Mine, plus curriculum points up to this level.
        case upTo(Int)
        case all
    }

    struct Entry: Identifiable, Hashable {
        let id: String
        var kind: AtomKind
        var title: String
        /// The rule, or the correction.
        var detail: String = ""
        var examples: [String] = []
        var level: Int?
        var pointID: String?
        var origins: Set<Origin> = []
        /// What opening it asks a lesson about.
        var seed: Atom.Seed
        /// Present when opening should count as a visit to a finding.
        var atom: Atom?
        var noted = 0
        var lastNoted: Date?
        /// The learner's own sentence it came out of.
        var sentence: String?
        /// The question that brought a suggestion.
        var question: String?
        var suggestedAt: Date?
        var used = 0
        var clean = 0
        /// "tomorrow", "3 days". Nil when not scheduled.
        var returns: String?
        var held = false

        var pinned: Bool { origins.contains(.kept) }
        var isMine: Bool { origins.contains { $0 != .curriculum } }
    }

    struct Section: Identifiable, Hashable {
        /// Nil for the pinned section.
        let kind: AtomKind?
        var entries: [Entry]
        var id: String { kind?.rawValue ?? "pinned" }
        var title: String { kind?.label ?? "Pinned" }
    }

    /// A link out of an ask answer, kept because the answer itself is not.
    struct Suggestion: Identifiable, Codable, Hashable {
        /// `Atom.identify(kind, subject)`, so the same recommendation twice is
        /// one row and it merges with a finding on the same point.
        var id: String { Atom.identify(kind, subject) }
        var kind: AtomKind
        var subject: String
        var headline: String
        /// Only ever an id the pack actually has.
        var pointID: String?
        var language: Language
        var question: String
        /// What the question was about — becomes the lesson's context.
        var context: String
        var at: Date

        init(kind: AtomKind, subject: String, headline: String, pointID: String?,
             language: Language, question: String, context: String, at: Date = .now) {
            self.kind = kind
            self.subject = subject
            self.headline = headline
            self.pointID = pointID
            self.language = language
            self.question = question
            self.context = context
            self.at = at
        }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(AtomKind.self, forKey: .kind)
            subject = try c.decode(String.self, forKey: .subject)
            headline = try c.decodeIfPresent(String.self, forKey: .headline) ?? ""
            pointID = try c.decodeIfPresent(String.self, forKey: .pointID)
            language = try c.decode(Language.self, forKey: .language)
            question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
            context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
            at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
        }

        /// Newest wins; the list is capped so UserDefaults stays small.
        static let cap = 300

        static func adding(_ new: [Suggestion], to list: [Suggestion]) -> [Suggestion] {
            func key(_ s: Suggestion) -> String { s.language.rawValue + "|" + s.id }
            let replaced = Set(new.map(key))
            let kept = list.filter { !replaced.contains(key($0)) }
            return Array((kept + new).suffix(cap))
        }
    }

    /// One problem finding as it landed in a review.
    struct Noted: Hashable {
        var atom: Atom
        var sentence: String
        var at: Date
    }

    static func pointEntryID(_ pointID: String) -> String { "point/\(pointID)" }

    // MARK: Assembly

    static func assemble(language: Language,
                         kinds: [AtomKind],
                         points: [GrammarPoint],
                         noted: [Noted],
                         progress: Progress,
                         suggestions: [Suggestion],
                         bank: [BankEntry],
                         scope: Scope,
                         search: String = "") -> [Section] {
        var entries: [String: Entry] = [:]
        var order: [String] = []
        func put(_ e: Entry) {
            if entries[e.id] == nil { order.append(e.id) }
            entries[e.id] = e
        }

        // Curriculum.
        for p in points {
            let use = progress.structures[p.id]
            put(Entry(id: pointEntryID(p.id), kind: p.kind, title: p.name,
                      detail: p.instruction, examples: p.examples, level: p.level,
                      pointID: p.id, origins: [.curriculum],
                      seed: Atom.Seed(subject: p.name, context: p.examples.first ?? "",
                                      pointID: p.id),
                      used: use?.attempts ?? 0, clean: use?.successes ?? 0))
        }
        let known = Set(points.map(\.id))

        // Noted. Oldest first, so the latest wording and sentence win.
        for n in noted.sorted(by: { $0.at < $1.at }) where n.atom.verdict.isProblem {
            let id = n.atom.id
            var e = entries[id] ?? Entry(id: id, kind: n.atom.kind, title: n.atom.seed.subject,
                                         seed: n.atom.seed)
            e.origins.insert(.noted)
            e.noted += 1
            e.lastNoted = n.at
            e.atom = n.atom
            e.seed = n.atom.seed
            e.sentence = n.sentence
            let s = n.atom.stages
            let line = [s.fix, s.note.isEmpty ? s.name : s.note].filter { !$0.isEmpty }
            if !line.isEmpty { e.detail = line.joined(separator: " — ") }
            else if e.detail.isEmpty { e.detail = s.locate }
            put(e)
        }

        // Encounters: schedule, and anything scheduled with no finding on record.
        for enc in progress.encounters.values where enc.language == language {
            var e = entries[enc.atomID] ?? Entry(
                id: enc.atomID, kind: enc.kind, title: enc.subject,
                seed: Atom.Seed(subject: enc.subject, context: "", pointID: nil))
            e.origins.insert(.noted)
            e.noted = max(e.noted, enc.sightings)
            e.lastNoted = max(e.lastNoted ?? enc.lastSeen, enc.lastSeen)
            e.returns = enc.dueAt == nil ? nil : enc.dueLabel
            e.held = enc.standing == .held
            put(e)
        }

        // Suggestions. Onto the point when the answer named one.
        for s in suggestions where s.language == language {
            let id = s.pointID.flatMap { known.contains($0) ? pointEntryID($0) : nil } ?? s.id
            var e = entries[id] ?? Entry(
                id: id, kind: s.kind, title: s.subject, detail: s.headline,
                seed: Atom.Seed(subject: s.subject, context: s.context, pointID: nil))
            e.origins.insert(.suggested)
            if (e.suggestedAt ?? .distantPast) <= s.at {
                e.suggestedAt = s.at
                e.question = s.question
            }
            put(e)
        }

        // Pins.
        for b in bank where b.language == language {
            let id = b.pointID.flatMap { known.contains($0) ? pointEntryID($0) : nil } ?? b.atomID
            var e = entries[id] ?? Entry(
                id: id, kind: b.kind, title: b.subject, detail: b.note,
                seed: b.seed)
            if e.detail.isEmpty { e.detail = [b.fix, b.note].filter { !$0.isEmpty }.joined(separator: " — ") }
            if e.sentence == nil, !b.sentence.isEmpty, b.pointID == nil { e.sentence = b.sentence }
            e.origins.insert(.kept)
            put(e)
        }

        // Filter.
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        let visible = order.compactMap { entries[$0] }.filter { e in
            switch scope {
            case .all: break
            case .mine: if !e.isMine { return false }
            case .upTo(let n): if !e.isMine, (e.level ?? 0) > n { return false }
            }
            guard !needle.isEmpty else { return true }
            return ([e.title, e.detail, e.sentence ?? ""] + e.examples)
                .contains { $0.lowercased().contains(needle) }
        }

        // Group.
        let pinned = visible.filter(\.pinned).sorted(by: rank)
        var sections: [Section] = pinned.isEmpty ? [] : [Section(kind: nil, entries: pinned)]
        let rest = Dictionary(grouping: visible.filter { !$0.pinned }, by: \.kind)
        let kindOrder = kinds + AtomKind.allCases.filter { !kinds.contains($0) }
        for kind in kindOrder {
            guard let list = rest[kind], !list.isEmpty else { continue }
            sections.append(Section(kind: kind, entries: list.sorted(by: rank)))
        }
        return sections
    }

    /// Yours before the syllabus; within that, most often noted, then most
    /// recent; the syllabus in level order, file order kept by the stable sort.
    private static func rank(_ l: Entry, _ r: Entry) -> Bool {
        if l.isMine != r.isMine { return l.isMine }
        if l.isMine {
            if l.noted != r.noted { return l.noted > r.noted }
            let a = max(l.lastNoted ?? .distantPast, l.suggestedAt ?? .distantPast)
            let b = max(r.lastNoted ?? .distantPast, r.suggestedAt ?? .distantPast)
            if a != b { return a > b }
        }
        return (l.level ?? 0) < (r.level ?? 0)
    }

    // MARK: The book's last chapter

    /// Everything of the learner's — noted, suggested, pinned — whose point
    /// no book entry carries, as a list chapter. Nil when there is none.
    /// Returns the textbook entries too, keyed by the chapter entry ids.
    static func notedChapter(language: Language, sections: [Section],
                             bookPoints: Set<String>, known: Set<String>)
        -> (chapter: Chapter, sources: [String: Entry])? {
        let prefix = chapterPrefix(language)
        var seen: Set<String> = []
        var entries: [Chapter.Entry] = []
        var sources: [String: Entry] = [:]
        for e in sections.flatMap(\.entries) where e.isMine && seen.insert(e.id).inserted {
            let point = (e.pointID ?? e.seed.pointID).flatMap { known.contains($0) ? $0 : nil }
            if let point, bookPoints.contains(point) { continue }
            let id = "\(prefix).noted.\(e.id)"
            entries.append(Chapter.Entry(id: id, head: e.title,
                                         gloss: e.detail.isEmpty ? nil : e.detail,
                                         group: e.kind.label, example: e.sentence,
                                         point: point))
            sources[id] = e
        }
        guard !entries.isEmpty else { return nil }
        let sub = entries.prefix(3).map(\.head).joined(separator: " · ")
        return (Chapter(id: "\(prefix).noted", name: "Noted", sub: sub, layout: .list,
                        entries: entries, formats: []), sources)
    }

    static func chapterPrefix(_ language: Language) -> String {
        switch language {
        case .mandarin: return "zh"
        case .german:   return "de"
        case .french:   return "fr"
        }
    }

    /// Where a Noted entry stands. No quiz reaches these, so it is read off
    /// the record: a scheduled finding is slipping until it holds.
    static func state(of e: Entry) -> EntryState {
        if e.held { return EntryState(standing: .holding, slipping: false, lastSeen: e.lastNoted, recent: []) }
        if e.noted > 0 { return EntryState(standing: .tried, slipping: true, lastSeen: e.lastNoted, recent: []) }
        if e.used > 0 {
            return EntryState(standing: e.clean > 0 ? .holding : .tried, slipping: false,
                              lastSeen: nil, recent: [])
        }
        return EntryState(standing: .never, slipping: false, lastSeen: nil, recent: [])
    }

    /// Every problem finding in these sessions, in one language.
    static func noted(in sessions: [Session], language: Language) -> [Noted] {
        var seen: Set<UUID> = []
        var out: [Noted] = []
        for session in sessions where session.language == language {
            for turn in session.turns where seen.insert(turn.id).inserted {
                for atom in turn.review?.atoms ?? [] where atom.verdict.isProblem {
                    out.append(Noted(atom: atom, sentence: turn.attempt.confirmed,
                                     at: Self.date(of: session)))
                }
            }
        }
        return out
    }

    /// Session ids start `yyyy-MM-dd`.
    private static func date(of session: Session) -> Date {
        day.date(from: String(session.id.prefix(10))) ?? .distantPast
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// The ask reply as the model writes it: the answer, and for each link the
/// curriculum point it names when there is one.
struct AskReply: Decodable {
    let id: String
    let question: String
    let answer: String
    let atoms: [Link]

    struct Link: Decodable {
        let kind: AtomKind
        let headline: String
        let subject: String
        let point: String?
    }

    var item: AskItem {
        AskItem(id: id, question: question, answer: answer,
                atoms: atoms.map { AtomLink(kind: $0.kind, headline: $0.headline, subject: $0.subject) })
    }

    func suggestions(language: Language, validPoints: Set<String>,
                     question asked: String, context: String, at: Date = .now) -> [Textbook.Suggestion] {
        atoms.map {
            Textbook.Suggestion(kind: $0.kind, subject: $0.subject, headline: $0.headline,
                                pointID: $0.point.flatMap { validPoints.contains($0) ? $0 : nil },
                                language: language, question: asked, context: context, at: at)
        }
    }
}
