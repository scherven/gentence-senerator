import Foundation

/// Where Talk is waiting, if anywhere. The conversation itself is in
/// `Store.conversations`.
enum TalkState: Equatable {
    case idle
    /// Writing the scene.
    case setting
    /// The partner's line is being written.
    case waiting
    case failed(String)
}

extension Store {

    /// This language's conversation: unstarted, running, or ended and not yet
    /// put away.
    var conversation: Conversation? { conversations[settings.language.rawValue] }

    private func put(_ conversation: Conversation?) {
        conversations[settings.language.rawValue] = conversation
        Vault.save(conversations, Vault.conversations)
    }

    /// A new scene, over any unanswered one.
    func newScene() async {
        guard talk != .setting else { return }
        if let held = conversation, !held.learnerLines.isEmpty, !held.ended { return }
        talk = .setting
        do {
            let (scene, usage) = try await tutor.scene(language: settings.language,
                                                       level: settings.level,
                                                       avoid: recentScenes)
            note(usage, model: Anthropic.reviewModel)
            put(Conversation(language: settings.language, level: settings.level, scene: scene))
            recentScenes = Array((recentScenes + ["\(scene.place): \(scene.want)"]).suffix(30))
            Vault.save(recentScenes, Vault.recentScenes)
            talk = .idle
        } catch {
            talk = .failed(Plain.message(error, "scene"))
        }
    }

    /// The learner's line, then the partner's.
    func say(_ text: String) async {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var live = conversation, !live.ended, !line.isEmpty, talk != .waiting,
              live.lines.last?.speaker == .partner, live.turnsLeft > 0 else { return }
        live.lines.append(.init(id: UUID(), speaker: .learner, text: line))
        put(live)
        await reply()
    }

    /// The partner's next line. Also the retry when one failed: the
    /// learner's line is already kept.
    func reply() async {
        guard let asked = conversation, !asked.ended,
              asked.lines.last?.speaker == .learner else { return }
        talk = .waiting
        do {
            let (line, usage) = try await tutor.partner(asked, last: asked.turnsLeft == 0)
            note(usage, model: Anthropic.reviewModel)
            // Put away or replaced while waiting.
            guard var live = conversation, live.id == asked.id,
                  live.lines.count == asked.lines.count else { talk = .idle; return }
            live.lines.append(.init(id: UUID(), speaker: .partner,
                                    text: line.say.trimmingCharacters(in: .whitespacesAndNewlines),
                                    move: line.move))
            if line.goal_met { live.goalMet = true }
            if line.move == .close || live.turnsLeft == 0 { live.ended = true }
            put(live)
            if live.ended { fileConversation(live) }
            talk = .idle
        } catch {
            talk = .failed(Plain.message(error, "partner"))
        }
    }

    /// The learner stops. What they said so far is graded.
    func endConversation() {
        guard var live = conversation, !live.ended else { return }
        live.ended = true
        put(live)
        talk = .idle
        fileConversation(live)
    }

    /// Into the archive and off to grading. Safe twice: the archive copy is
    /// replaced and only unfiled answers make a job.
    private func fileConversation(_ conversation: Conversation) {
        let session = conversation.session()
        guard !session.turns.isEmpty else { return }
        file(session)
        enqueue(session)
        Task { await pump() }
    }

    /// Put away: the next Talk starts a new scene. An unanswered scene is
    /// dropped; a started one is ended and graded first.
    func closeConversation() {
        if conversation?.ended == false { endConversation() }
        put(nil)
        talk = .idle
    }
}
