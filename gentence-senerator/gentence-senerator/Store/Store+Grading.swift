import Foundation

extension Store {

    // MARK: Grading

    /// Files a finished session for grading. Nothing is sent here, so this is
    /// safe offline and at launch; `pump` does the sending.
    func enqueue(_ session: Session) {
        let exchanges = Store.unfiled(session, jobs: jobs)
        guard !exchanges.isEmpty else { return }
        // A session from before sessions carried a level, retired after a
        // language switch, can only take the setting — which is shared.
        jobs.append(GradingJob(id: UUID(), sessionID: session.id, language: session.language,
                               mode: session.mode, createdAt: .now,
                               level: session.level ?? settings.level, exchanges: exchanges))
        saveJobs()
    }


    /// Moves every job one step on: hands what is unsent to the background
    /// uploader, tells the push worker about anything it is not watching,
    /// counts what is graded, and reads in whatever has finished. Safe to call
    /// as often as liked; a failure in one job or one step is retried on the
    /// next call and never stops the others.
    /// `backgroundOnly`: submit and read what came back, nothing slow — iOS
    /// gives the app seconds once it is put away.
    func pump(backgroundOnly: Bool = false) async {
        guard !pumping else { return }
        pumping = true
        defer { pumping = false }

        for id in jobs.map(\.id) {
            guard var job = jobs.first(where: { $0.id == id }), job.state != .done else { continue }
            do {
                if job.batchID == nil {
                    if !job.uploading, mayUpload(job.id) { try submit(&job) }
                    put(job)
                    continue
                }
                guard let batchID = job.batchID else { continue }

                if !job.watched, await watch(batchID, job: job.id, label: label(of: job)) {
                    job.watched = true
                }

                let batch = try await tutor.api.retrieveBatch(batchID)
                job.graded = batch.succeeded
                job.failed = batch.failed
                job.error = nil
                // Past the switch, the worker may have cancelled the batch and
                // graded it directly: its results come first, and while it is
                // still grading, the cancelled batch is left alone.
                var results: [Anthropic.BatchResult]?
                var direct = false
                if Store.pastSwitch(job) {
                    switch await directResults(batchID) {
                    case .pending: put(job); continue
                    case .ready(let graded): results = graded; direct = true
                    case .none, .unknown:
                        // Cancelled means the worker stepped in, whatever this
                        // answer said: a stale 404 or a dropped request is not
                        // a reason to read the cancelled batch and pay twice.
                        // A quarter of an hour on, its results are not coming.
                        if batch.canceled > 0,
                           Date.now < Store.switchAt(job).addingTimeInterval(Store.directGrace) {
                            put(job); continue
                        }
                    }
                }
                if results == nil, batch.ended {
                    results = try await tutor.api.batchResults(batch)
                }
                if let results {
                    ingest(results, into: job, batched: !direct)
                    job.graded = results.filter { $0.reply != nil }.count
                    job.failed = results.count - job.graded
                    job.state = .done
                    if job.returnedAt == nil {
                        job.returnedAt = .now
                        if let sent = job.sentAt {
                            gradingTimes = GradingClock.adding(Date.now.timeIntervalSince(sent), to: gradingTimes)
                            Vault.save(gradingTimes, Vault.gradingTimes)
                        }
                    }
                }
            } catch {
                job.error = Plain.message(error, "batch results")
            }
            put(job)
        }

        // A failed answer gets one second attempt on its own, outside the
        // batch — where the refusal fallback is allowed. After that it waits
        // for Retry.
        // Detached: each is a slow live call, and the pump has other
        // languages' batches to read in. `regrading` keeps it to one at a time.
        for id in jobs.map(\.id) where !backgroundOnly {
            guard var job = jobs.first(where: { $0.id == id }),
                  job.state == .done, !job.retried, hasFailures(job) else { continue }
            job.retried = true
            put(job)
            Task { await gradeMissing(of: job) }
        }

        // Done jobs stay a day and a half, so the screen can still say what
        // came back.
        let cutoff = Date.now.addingTimeInterval(-36 * 3600)
        jobs.removeAll { $0.state == .done && ($0.returnedAt ?? $0.createdAt) < cutoff }
        saveJobs()
    }

    private func label(of job: GradingJob) -> String {
        "\(job.language.name) \(job.mode.name.lowercased())"
    }

    /// Hands a job to the background uploader. From here iOS owns it: it goes
    /// when there is signal, with or without the app, and `submitted` hears
    /// back.
    func submit(_ job: inout GradingJob) throws {
        guard let body = try body(of: job) else {
            job.state = .done
            return
        }
        let token = UserDefaults.standard.string(forKey: Vault.pushToken)
        try sender.send(job: job.id, body: body, token: token, label: label(of: job))
        job.uploading = true
        job.error = nil
    }

    /// The batch a job sends. Nil when none of its answers can be found.
    func body(of job: GradingJob) throws -> Data? {
        let level = job.level ?? settings.level
        let requests: [[String: Any]] = job.exchanges.compactMap { exchange in
            let turns = exchange.turnIDs.compactMap(archived)
            guard let last = turns.last else { return nil }
            return ["custom_id": exchange.customID,
                    "params": tutor.reviewParams(turn: last, history: Array(turns.dropLast()),
                                                 level: level)]
        }
        guard !requests.isEmpty else { return nil }
        return try Schemas.data(["requests": requests])
    }

    /// Sends a job from the app, now, beside whatever iOS is holding for it.
    func sendNow(_ job: GradingJob) async {
        guard job.batchID == nil, sendingNow.insert(job.id).inserted else { return }
        defer { sendingNow.remove(job.id) }
        do {
            guard let body = try body(of: job) else { return }
            let accepted = try await sender.sendNow(
                job: job.id, body: body,
                token: UserDefaults.standard.string(forKey: Vault.pushToken),
                label: label(of: job))
            submitted(job.id, .success(accepted))
            await pump()
        } catch {
            if var now = jobs.first(where: { $0.id == job.id }) {
                now.error = online ? Plain.message(error, "send now") : "Still no connection."
                put(now)
            }
        }
    }

    /// The uploader's answer, possibly delivered with the app in the
    /// background. Saved before anything else: this is the only record of
    /// which batch the answers became.
    func submitted(_ id: UUID, _ result: Result<Sender.Accepted, Error>) {
        guard var job = jobs.first(where: { $0.id == id }) else { return }
        job.uploading = false
        noteUpload(id, result)
        // Sent both ways: the second answer is the same batch, or a failure
        // that no longer matters.
        if job.batchID != nil {
            put(job)
            return
        }
        switch result {
        case .success(let accepted):
            job.batchID = accepted.batch
            job.state = .grading
            job.sentAt = .now
            // What the upload carried, not what has arrived since.
            job.watched = accepted.watched
            job.error = nil
        case .failure(let error):
            job.error = Plain.message(error, "upload")
        }
        put(job)
    }

    /// An upload iOS no longer holds — the app was reinstalled, or the
    /// system dropped it — is sent again. The worker returns the batch it
    /// already made if the first one did arrive.
    private func reconcileUploads() async {
        let flying = await sender.inFlight()
        for var job in jobs where job.uploading && !flying.contains(job.id) {
            job.uploading = false
            put(job)
        }
    }

    /// Answers the batch did not grade, graded one at a time on the spot.
    /// Each is saved as it lands, so being interrupted loses only the one in
    /// flight.
    private func gradeMissing(of job: GradingJob) async {
        guard regrading.insert(job.id).inserted else { return }
        defer { regrading.remove(job.id) }
        let level = job.level ?? settings.level
        for exchange in job.exchanges {
            let turns = exchange.turnIDs.compactMap(archived)
            guard let last = turns.last, last.review == nil else { continue }
            do {
                let (review, usage) = try await tutor.review(
                    turn: last, history: Array(turns.dropLast()), level: level)
                noteGraded(note(usage, model: Tutor.reviewModel(last.mode)), answers: turns.count)
                land(review, on: last)
            } catch {
                if var now = jobs.first(where: { $0.id == job.id }) {
                    now.error = Plain.message(error, "regrade")
                    put(now)
                }
            }
        }
        refreshPlan()
    }

    /// One review into the archive, and everything it is evidence of into
    /// `Progress`.
    func land(_ review: Review, on turn: Turn) {
        amend(turn.id) { $0.review = review }
        var graded = turn
        graded.review = review
        record(for: graded, review: review)
        reached(review, in: graded)
        noteResult(graded, review: review)
        if scores.add(graded) { Vault.save(scores, Vault.scores) }
    }

    /// Reviews into the archive, in the order the answers were given.
    /// Idempotent: an answer already reviewed is skipped, so a crash halfway
    /// through costs nothing on the next pass.
    /// `batched` false when the worker graded it with ordinary calls, at full price.
    private func ingest(_ results: [Anthropic.BatchResult], into job: GradingJob, batched: Bool) {
        let byID = Dictionary(results.map { ($0.customID, $0) }, uniquingKeysWith: { a, _ in a })
        for exchange in job.exchanges {
            guard let result = byID[exchange.customID], let reply = result.reply else { continue }
            let turns = exchange.turnIDs.compactMap(archived)
            guard let last = turns.last, last.review == nil else { continue }
            noteGraded(note(reply.usage, batched: batched, model: Tutor.reviewModel(last.mode)),
                       answers: turns.count)
            guard let review = try? Tutor.read(reply, turn: last,
                                               history: Array(turns.dropLast()))
            else { continue }
            land(review, on: last)
        }
        // What the reviews put into `Progress` moves the record on screen.
        refreshPlan()
    }

    /// Tells the push worker to notify this device when the batch ends — for
    /// a job submitted before the device had a token. False when it could
    /// not, so the next pump tries again.
    private func watch(_ batchID: String, job: UUID, label: String) async -> Bool {
        guard let token = UserDefaults.standard.string(forKey: Vault.pushToken) else { return false }
        var request = URLRequest(url: Worker.url("/watch"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        Worker.authorize(&request)
        request.httpBody = try? JSONSerialization.data(
            withJSONObject: ["batch": batchID, "job": job.uuidString, "token": token, "label": label,
                             "sandbox": Sender.sandbox])
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    private func saveJobs() { Vault.save(jobs, Vault.grading) }

    /// By id: the list can change under an await.
    func put(_ job: GradingJob) {
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[index] = job
        saveJobs()
    }

    /// Anything not yet handed to the uploader or not yet watched, so going
    /// to the background can ask for time to finish it.
    var hasUnsent: Bool {
        jobs.contains { ($0.batchID == nil && !$0.uploading) || ($0.batchID != nil && !$0.watched) }
    }

    /// Everything the app does on coming to the front, in order: a session
    /// left open since yesterday is filed and graded before today can be
    /// written over it; lost uploads are resent; what finished is read in;
    /// then the day — and, once today's feedback is in, tomorrow — is written.
    /// Polls while anything is out, so the graded count moves on screen.
    func wake() async {
        backfillActivity()
        retireStale()
        await reconcileUploads()
        await pump()
        notificationsOn = await Push.allowed()
        await prepareDay()
        polling?.cancel()
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard let self, self.jobs.contains(where: { $0.state != .done }) else { return }
                await self.pump()
            }
        }
    }

    func sleep() {
        polling?.cancel()
        polling = nil
    }

    /// Grades the answers a finished job is still missing, on the spot.
    func regrade(_ job: GradingJob) {
        Task { await gradeMissing(of: job) }
    }

    // MARK: Reading

    /// The graded reviews of one job, one screen per exchange.
    func read(_ job: GradingJob) {
        let ids = job.exchanges.compactMap(\.turnIDs.last)
            .filter { archived($0)?.review != nil }
        guard let first = ids.first, let turn = archived(first) else { return }
        if let i = jobs.firstIndex(where: { $0.id == job.id }), jobs[i].readAt == nil {
            jobs[i].readAt = .now
            saveJobs()
        }
        session = nil
        knowledge = [:]
        path = []
        reading = ids
        current = turn
        phase = .reviewing
    }


    /// How far along the wait for the switch to direct grading, 0–0.95.
    func gradingProgress(_ job: GradingJob) -> Double {
        GradingClock.progress(sentAt: job.sentAt ?? job.createdAt, expected: Store.directAfter)
    }

    /// The worker cancels a batch that has not ended this long after it was
    /// sent and grades it directly (worker/src/index.js, DIRECT_AFTER_MS).
    nonisolated static let directAfter: TimeInterval = 20 * 60

    nonisolated static func switchAt(_ job: GradingJob) -> Date {
        (job.sentAt ?? job.createdAt).addingTimeInterval(directAfter)
    }

    nonisolated static func pastSwitch(_ job: GradingJob, now: Date = .now) -> Bool {
        now >= switchAt(job)
    }

    /// `none`: the worker did not step in, as far as it says. `unknown`: no
    /// usable answer — offline, limited, a timeout.
    enum Direct { case none, unknown, pending, ready([Anthropic.BatchResult]) }

    /// How long past the switch a cancelled batch waits for the worker's
    /// direct results before it is read as it stands.
    nonisolated static let directGrace: TimeInterval = 15 * 60


    private func mayUpload(_ id: UUID) -> Bool {
        (uploadHolds[id]?.next ?? .distantPast) <= .now
    }

    /// A malformed or refused request fails the same way every time, so it
    /// is not sent again this launch. Anything else waits, longer each time,
    /// so a limit is not spent on retries.
    private func noteUpload(_ id: UUID, _ result: Result<Sender.Accepted, Error>) {
        guard case .failure(let error) = result else { uploadHolds[id] = nil; return }
        let failures = (uploadHolds[id]?.failures ?? 0) + 1
        var next = Date.now.addingTimeInterval(min(60 * pow(2, Double(failures - 1)), 30 * 60))
        if case Sender.Failure.rejected(let code, _) = error, code == 400 || code == 403 {
            next = .distantFuture
        }
        uploadHolds[id] = (next, failures)
    }

    /// What the worker graded directly for a batch, if it stepped in.
    private func directResults(_ batchID: String) async -> Direct {
        guard var parts = URLComponents(string: Worker.base + "/results") else { return .none }
        parts.queryItems = [URLQueryItem(name: "batch", value: batchID)]
        guard let url = parts.url else { return .none }
        var request = URLRequest(url: url)
        Worker.authorize(&request)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let code = (response as? HTTPURLResponse)?.statusCode else { return .unknown }
        switch code {
        case 200: return .ready(Anthropic.results(from: data))
        case 202: return .pending
        case 404: return .none
        default: return .unknown
        }
    }

    /// Where a job stands, in the learner's words.
    func status(of job: GradingJob) -> String {
        switch job.state {
        case .unsent:
            if sendingNow.contains(job.id) { return "Sending…" }
            if !online { return "Offline" }
            return job.uploading ? "Sending…" : "Not sent"
        case .grading:
            let left = Store.switchAt(job).timeIntervalSinceNow
            guard left > 0 else { return "Grading directly" }
            return "Direct in \(Int(left) / 60):" + String(format: "%02d", Int(left) % 60)
        case .done:
            let missing = job.exchanges.filter {
                $0.turnIDs.last.flatMap(archived)?.review == nil
            }.count
            if missing == 0 { return "Graded" }
            return regrading.contains(job.id) ? "Grading \(missing) again…" : "Graded, \(missing) failed"
        }
    }

    func canRead(_ job: GradingJob) -> Bool {
        job.exchanges.contains { $0.turnIDs.last.flatMap(archived)?.review != nil }
    }

    func hasFailures(_ job: GradingJob) -> Bool {
        job.state == .done && !regrading.contains(job.id) && job.exchanges.contains {
            $0.turnIDs.last.flatMap(archived)?.review == nil
        }
    }

    /// Structures the deep review says the sentence actually used, asked for or
    /// not. One tag is not proof — the model over-tags — so each is filed as an
    /// attempt and `neverReached` decides how many make a habit. The point the
    /// prompt asked for is skipped: `record` already counted it, and counting
    /// it twice would retire it off a single turn.
    func reached(_ review: Review, in turn: Turn) {
        for pointID in review.usedPoints where pointID != turn.prompt.pointID {
            progress.attempted(pointID: pointID, language: turn.language,
                               succeeded: Store.clean(review, on: pointID))
        }
        if !review.usedPoints.isEmpty { save() }
    }

    /// No problem finding on the point. Reviews from before findings named
    /// their point tag every finding with the asked-for one, so there this is
    /// the whole sentence, as it always was.
    nonisolated static func clean(_ review: Review, on pointID: String) -> Bool {
        !review.problems.contains { $0.seed.pointID == pointID }
    }

    /// Everything a landed review is evidence of. Nothing here waits for a tap:
    /// a finding the learner reads and moves past is still something they got
    /// wrong.
    func record(for turn: Turn, review: Review) {
        // Reach. A point counts as attempted whether or not it worked — that is
        // what separates reach from repetition.
        if let pointID = turn.prompt.pointID {
            progress.attempted(pointID: pointID, language: turn.language,
                               succeeded: Store.clean(review, on: pointID))
            if pointID == stretch?.id { stretch = nil }
        }

        // Reach, again, and the half that needs no call. Only where the words
        // are the learner's own: in listen they are writing down someone
        // else's sentence, and a word transcribed is not a word produced.
        if turn.mode != .listen {
            progress.produced(lexicon.words(in: turn.attempt.confirmed,
                                            language: turn.language),
                              language: turn.language)
        }

        // Repetition. A due subject was woven into the sentence; whether it came
        // back clean is the retrieval check the schedule was waiting on.
        // A point woven in by name, because a quiz missed it, is wrong when a
        // finding names the point.
        let pack = LanguagePacks.pack(for: turn.language)
        for subject in turn.prompt.revisited {
            let point = pack.points.first { $0.name.lowercased() == subject.lowercased() }?.id
            let wrong = review.problems.contains {
                $0.seed.subject.lowercased() == subject.lowercased()
                    || (point != nil && $0.seed.pointID == point)
            }
            if wrong {
                progress.missed(subject: subject, language: turn.language)
            } else {
                progress.retrieved(subject: subject, language: turn.language)
            }
        }

        let woven = Set(turn.prompt.revisited.map { $0.lowercased() })
        for atom in review.problems {
            progress.saw(atom, language: turn.language,
                         woven: woven.contains(atom.seed.subject.lowercased()))
        }
        save()
    }

    // MARK: Review

    /// Graded turns of a batch being read, in order. For the summary.
    func reviewed(_ ids: [UUID]) -> [Turn] {
        ids.compactMap { id in
            archived(id) ?? session?.turns.first { $0.id == id }
        }.filter { $0.review != nil }
    }

    /// The verdict `grade(_:against:)` returns when the model could not be reached.
    static let uncheckable = "Unchecked."

    /// The ask panel's failure line, with the reason when there is one.
    static func couldNotAnswer(_ why: String) -> String {
        why == Plain.unknown ? "No answer." : "No answer. " + why
    }
}
