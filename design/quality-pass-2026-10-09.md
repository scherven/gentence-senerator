# Quality pass 2026-10-09: open findings and reviewer notes

## Big findings (need a decision)

1. **[high/state] Store.swift:1461** Retrieval is judged by exact match between the woven subject string and the model's free-text `seed.subject` on a problem atom. The reviewer is never told which subjects were woven in (Tutor.attemptFacts has no revisit list). So any rewording of the same mistake is credited as a clean retrieval.
   - Scenario: The woven subject is "了 after completed action". The learner misuses 了 again, and the review files it with the subject "了" or "completed-action 了". No problem atom matches the string, so `progress.retrieved` runs, the encounter climbs a rung, and three such turns retire it as held even though the learner got it wrong every time.
   - Fix: Pass `turn.prompt.revisited` to the reviewer and ask for a per-subject retrieved/missed verdict in the schema. Or at minimum, match on encounter/atom id (`Atom.identify(kind, subject)`) and treat a problem atom of the same kind in the same span as a miss.

2. **[high/state] Tutor.swift:223** Every finding in a reviewed turn gets `seed.pointID = turn.prompt.pointID`. So in a stretch turn, each unrelated error (a tone, a measure word) is attributed to the stretch point.
   - Scenario: The produce stretch is the 把 construction, and the answer has a tone error and a measure-word error but uses 把 correctly. Both atoms carry pointID 把. `Textbook.uses(of:)` (Textbook.swift:328) lists the sentence as a broken use of 把 with the tone fix. `Store.noted(point:)` (Store.swift:2589) lists both findings under 把. The per-point page tells the learner they keep failing a point they used correctly.
   - Fix: Leave `seed.pointID` nil unless the model names the point for that finding: add an optional `point` per finding to the review schema, validated against `pack.pointIDs`. Keep the prompt's point only on `Turn.Prompt.pointID`.

3. **[medium/state] Activity.swift:7** ActivityLog has no listen mark. Listen is one of the three core modes, but finishing a dialogue or a clip session never marks the History calendar, and `shade(.all)` only needs translate+produce+quiz.
   - Scenario: The learner does produce, translate and a dialogue today and no quiz. The calendar cell shows 'some' with two ticks; a day of produce, translate and a quiz shows 'all'. `finishPassage` (Store.swift:1712) writes neither activity nor scores.
   - Fix: Add `.listen` to `Mark`, set it in `finishPassage` and in `mark(for:)` for listen sessions, and decide whether quiz still counts toward `.all`. The calendar view changes, so confirm with Simon.

4. **[medium/state] Textbook.swift:154** Suggestions and pins with a known pointID merge onto the curriculum entry `point/<id>` (lines 186 and 200), but noted findings and encounters are keyed by atom id and never merge. One point shows up as two textbook rows: the curriculum row with used/clean counts and a separate 'noted' row with the findings.
   - Scenario: A finding on the 了 point (seed.pointID set) lands. The Textbook shows 'point/zh.le' with used 3, clean 1 and, separately, 'tense-aspect/了' noted ×2 with a returns date. The per-point page (`noted(point:)`) and the textbook row disagree about what is recorded for the point.
   - Fix: In the noted loop, apply the same rule as suggestions/bank: if `n.atom.seed.pointID` is in `known`, merge into `pointEntryID`. Do this only after fixing the Tutor.swift:223 attribution, or every stretch-turn finding collapses onto the stretch.

5. **[medium/state] Store.swift:1444** Whether a point was 'used' and whether it 'worked' have two definitions that disagree. `Progress.structures` counts the prompt's point plus `usedPoints`, with success meaning the whole sentence had no problems at all. `Textbook.uses(of:)` counts turns with an atom whose `seed.pointID` matches, with clean meaning no problem atom on that point. Turns tagged only through `usedPoints` never appear in `uses`.
   - Scenario: The learner uses 把 correctly in a sentence with an unrelated word-choice error. Progress records attempts+1 and successes+0, so the point reads 'tried, with errors'. The point page's uses list has no entry at all, because no atom names the point. On another day `uses` shows a clean 把 use while `structures` counts it as failed.
   - Fix: One evidence record per (turn, point) with its own verdict, written once at `land` and read by both DayPlan.standing and the point page; see the notes. In the short term, judge success as 'no problem atom on this point' rather than `review.problems.isEmpty`.

6. **[low/state] Store.swift:2200** A point has two standings that never meet. The Book reads quiz holding plus production solid (`state(of: Chapter.Entry)`). The Today record and the stretch picker read production only (`DayPlan.standing`, `neverReached`). A point that holds in quizzes shows 'never used' on Today, and quiz misses never reach the stretch or the schedule.
   - Scenario: The learner gets the 把 entry right 3 times in a row in quizzes, so the Book shows holding. The Today record cell for 把 is still 'never used'. Separately, missing 条 in five quiz rounds schedules nothing in Progress and does not raise its weight as a stretch candidate.
   - Fix: Keep the settled rule (quizzes can give at most holding), but read both from one per-point record: the Today cell can show quiz-holding as a lighter variant, and `pickStretch` can prefer points the learner recognizes but has never produced.

7. **[low/state] Lexicon.swift:81** `WordSeeds.read` picks 'have' words from the band words never produced and 'new' words at random from the band above. It ignores the vocab and word-deck evidence in QuizLog (`vocab.<lang>.<w>`). Production counts (`Progress.words`) likewise never inform the deck.
   - Scenario: The learner marks 机场 as known in the word deck, or misses it five times. Neither changes whether it is seeded into tomorrow's sentences. A word said 40 times in produce still comes due in the word deck as if unseen.
   - Fix: Prefer deck-holding words that have never been produced as 'have' seeds and deck-missed words as 'new'. Let `progress.timesProduced` above some threshold count as a right answer in `VocabDrill.isDue`.

8. **[low/state] Store.swift:1947** There are four score averages with different rules: `Session.averageScore`, `todayTally`, `todayScores`, and `LevelOffer.read` include listen turns; `ScoreLog.average` excludes them. The DayDraw word-seed closure is also copied verbatim between `nextDraw` (650) and `refreshPlan` (723).
   - Scenario: On the same day, the Today tally shows 62 (with a 0-scored dialogue) while History's average for the day shows 78.
   - Fix: Extract one drawDay(on:slot:) helper for nextDraw and refreshPlan (small). Keep Session.averageScore as it is. Decide with Simon whether the Today tally and scores should follow ScoreLog's produce/translate-only rule. Separately, stop scoring a gist-less dialogue as 0, for example by giving it no score.

9. **[medium/secondary] Store.swift:2200** An entry's standing in the Book and in quiz weighting uses production evidence only when the point is solid. Production holding, tried or failing is dropped, so the Book can show 'never' for a point Today has seen used or failing.
   - Scenario: The learner used point P cleanly twice in produce, so DayPlan.standing is .holding, but has never quizzed P's entry. state(of:) passes pointSolid=false, and QuizLog.state returns .never. The Book ledger shows never used, and QuizRound.weight gives it 4, the same as a point the learner has never touched. The reverse also holds: a point failing in production does not mark its entry as slipping.
   - Fix: Combine the two: standing = max(quiz standing, production standing), with solid still coming only from production. Treat a production .failing after a hold as slipping, so the Book and quiz assembly read the same learner record as Today.

10. **[medium/secondary] Vocab.swift:125** Meaning-to-word cards show only the English gloss, and many glosses are shared by several list words, so the learner can recall a correct word and still have to mark the card wrong.
   - Scenario: vocab-german.json has 193 glosses shared by two or more words: 'end' is Ende and Schluss, 'back' is Rücken and zurück. French has 105, Mandarin 369. The card says 'end' and the back says 'das Ende'. A learner who said 'der Schluss' self-marks wrong, which resets that word's streak in the log.
   - Fix: When a gloss is not unique within the language, skip the meaning-to-word direction for that word, or add a disambiguator such as the pos or 'not Schluss'. Alternatively have tools/build_words.py make glosses unique.

11. **[high/grading] index.js:214** The direct-grading claim never expires. If a gradeDirectly run dies before its final put, the batch is already cancelled, `watch:` stays `direct:true` (poll skips it), and `res:` stays pending for 3 days, so the job hangs on 'Grading directly' with no push and no recovery.
   - Scenario: A review call takes about 2 minutes (high effort, 32k max_tokens), and every request is awaited inside one scheduled invocation, sequentially across watches (poll line 207). Cloudflare caps a sub-hourly cron's wall time well below that (30s as I understand it), and any exception after line 217 does the same damage. The app sees 202 on every pump (Store.swift 1086, `case .pending: put(job); continue`), the job is never marked done, and pruning (which only removes done jobs) never clears it.
   - Fix: Store `directAt` in the claim and let poll reclaim a claim older than a few minutes. Grade per request and write each result as it lands (or move the work to a Queue or Durable Object) rather than one Promise.all inside the cron. App side, give up on a 202 older than about 30 min and fall back to gradeMissing.

12. **[medium/grading] index.js:68** The /submit idempotency check is a KV get followed by a create and then a put. Concurrent submissions of the same job, which the app does on purpose with Send now beside the background upload, both miss and create two batches.
   - Scenario: Send now (Sender.swift 71) runs while iOS still holds the background upload for the same job. Both requests reach /submit within the roughly 1s that batch creation takes, and KV is eventually consistent across edges anyway. Both see no `job:` key, both create a batch, both store `req:` and `watch:`. The second is billed and graded, and it pushes a second notification. The app ignores the second batch id (submitted() returns early), so its results are paid for and never read.
   - Fix: App side (small on its own): have pump skip jobs in `sendingNow`. Worker side: serialise per job id with a placeholder written before the create, or a Durable Object.

13. **[medium/grading] index.js:89** The direct-grading fallback only runs for batches with a `watch:` key, and that key is only written when the upload carried a push token. A late /watch also resets `since`, so the 20-minute switch counts from the watch, while the app counts from sentAt.
   - Scenario: An upload goes without a token (first launch before APNs registration, or a simulator). No watch is created, so poll never sees the batch and never grades it directly. Meanwhile the app counts down 'Direct in m:ss' and then shows 'Grading directly' for what may be hours. If the token arrives later and pump calls /watch (Store.swift 1286), `since: Date.now()` restarts the clock. If that /watch lands after the worker already graded directly and deleted the watch, the cancelled batch reads as `ended` on the next cron and pushes a second '0 graded, N failed'.
   - Fix: Always write a watch record from /submit (token optional; push only when one is present), and have /watch merge into the existing record, keeping `since` and `direct`. Have /watch refuse when `res:` already exists.

14. **[medium/grading] Anthropic.swift:28** Raw error descriptions reach the learner, including HTTP codes, worker bodies ('slow down', 'invite'), decoding paths and up to 400 characters of raw model JSON. This breaks the no-internal-machinery rule.
   - Scenario: A daySet reply misses a field. phase = .failed(error.localizedDescription) (Store.swift 773, 997) shows "Unexpected response: no `items` in the root — {\"items\":[..." in Trouble. Ask (Store.swift 2014) appends "Couldn't answer that: Request failed (429). slow down" as the answer text. lessonError (1868, 1897) works the same way. A refusal shows "The model declined: …".
   - Fix: Map Anthropic.Failure, URLError and Sender.Failure to a few terse learner strings at the Store boundary ('No connection.', 'Busy. Try again.', 'Couldn't write that.'), and log the detail instead.

15. **[medium/grading] Tutor.swift:206** Model text goes straight into the archive, the screen and Progress without validation. The glitches already seen (newlines with leaked 'instead: …' deliberation, broken escapes like f"ur or du00e9placement) are persisted, and because atom ids come from `subject` they also split learner evidence.
   - Scenario: A review finding's subject comes back as "f\"ur + Akkusativ". Atom.identify gives `kind/f"ur + akkusativ`, a new atom separate from the `für` one, so progress.saw files the miss under a key nothing else hits. The same glitch in a daySet `target` or `reference` (Tutor.swift 543-551) is shown verbatim as the day's question. A produce target with two questions or a newline is not checked either, though the schema description asks for it.
   - Fix: Add one validator in Tutor for short single-line fields (subject, target, english, reference, fix): reject a newline, a `u00[0-9a-f]{2}` sequence, `"` between letters, and '…instead:' or 'sorry,' deliberation markers. Throw .malformed so the existing regrade or retry path runs, and skip a single bad finding rather than ingesting it.

16. **[medium/grading] index.js:42** /health is unauthenticated and does a KV list on every hit. The free tier allows 1,000 lists a day and the */2 cron already uses 720, so about 280 /health hits stop all pushes and direct grading for the rest of the day.
   - Scenario: An uptime checker hitting /health every minute (1,440 a day), or anyone curling the public workers.dev URL, uses up the list quota. poll's `env.STATE.list` then throws and every scheduled run fails until the quota resets. Batches end with nobody pushing, and stalled batches are never graded directly.
   - Fix: Put /health behind admit(), or answer it without listing (e.g. a counter key the cron writes).

17. **[low/grading] index.js:199** poll does no per-watch error handling, and on an ended batch it deletes the watch before pushing. One throw (providerToken import, a retrieve network error, JSON.parse of `req:`) aborts the rest of the run, and a push that throws after the delete is lost for good.
   - Scenario: A transient failure in providerToken while pushing batch A. A's watch is already deleted, so no push ever comes for it. Batches B and C later in the list wait for the next run, or longer if A's failure repeats.
   - Fix: Wrap each iteration in try/catch, and delete the watch only after the push succeeds or returns a non-retryable 4xx.

18. **[low/grading] Schemas.swift:150** The rung schema, the lesson block construction and the worker's Anthropic headers are each written more than once.
   - Scenario: The rung object is copied verbatim in Schemas.lessonPractice (118-125) and Schemas.review (150-157). The rule, contrast, examples and drills block assembly appears in Tutor.expand and practice (57-80, 105-119) and again in Tutor.lesson(from:) (248-286). In the worker, the x-api-key and anthropic-version header pair is rebuilt in 5 places, and line 230 hard-codes the beta string next to the `BETA` constant on line 37. A change to the contrast side's 'What you used.' note or to rung fields has to be made twice.
   - Fix: Add `Schemas.rung` as a static. Add one `Lesson.blocks(rule:contrast:examples:drills:seed:)` builder used by both paths. Add `anthropicHeaders(env, extra)` in the worker and use BETA.

19. **[low/grading] index.js:72** /submit calls JSON.parse on the body outside a try, so a truncated or corrupt upload throws a 500 Worker exception instead of a 400. The app then treats it like any other failure and resends the same bad file on every pump.
   - Scenario: A background upload is retried from a partially written file, or the body is empty. The worker throws, iOS reports a 500, and Store resubmits every 20s.
   - Fix: Use try/catch returning 400, as the /anthropic path already does on line 156. Pair it with the app-side rule of no retry on 4xx.

20. **[medium/ui] LessonScreen.swift:55** If loading the practice fails, 'Writing practice' spins forever, and the single global lessonError can show up on a different lesson.
   - Scenario: loadPractice throws and sets store.lessonError, but the lesson exists with hasPractice == false. LessonHost shows the lesson, so the error never appears, and the Ticker spins with no retry. If another lesson's core load is in flight (pushed on top), its LessonHost now finds `lessonError` set and shows the first lesson's error until its own load lands.
   - Fix: Key load errors by request (`lessonErrors[cacheKey]`, plus `practiceErrors`). In LessonScreen, replace the Ticker with a TinyButton retry when practice failed, and have LessonHost read only its own request's error.

21. **[medium/ui] Theme.swift:141** Every face is a fixed-point UIFont with no scaling, so the whole app ignores Dynamic Type.
   - Scenario: A learner with Larger Text on sees body text at 16pt, meta at 11pt and labels at 11pt, unchanged. Fixed frames such as ActionKey's 50pt height, the 44pt PageHeader and the 48pt calendar cells were never designed for scaled text.
   - Fix: In `face(_:_:bold:)`, scale with `UIFontMetrics(forTextStyle:).scaledFont(for:)`, or use `Font.custom(name, size:, relativeTo:)` with a text style per token. Cap with `.dynamicTypeSize(...DynamicTypeSize.accessibility1)` at the root, then check fixed-height keys at XL sizes.

22. **[low/ui] QuizScreen.swift:64** The quiz and the ALL LANGUAGES runner each build their own header row (✕/STOP, a centred count, a 44pt balancing slot) instead of using PageHeader.
   - Scenario: QuizScreen.runner (lines 64–80) and AllLanguagesScreen.runner (AllLanguages.swift 52–66) re-create PageHeader's `.end(word)` lead with different fonts: mono 16 ✕ or mono 12 bold STOP, against PageHeader's meta caps. Every other full-screen sitting uses PageHeader, so these two headers do not match the rest of the app.
   - Fix: Use `PageHeader(lead: .end("Stop"), title: counter, onLead: quit) { Text("×\(streak)") }` or a small shared `RunnerHeader` in Ledger.swift. Choosing which font both runners should share is a visual call.

23. **[low/ui] DialoguePicker.swift:149** The dialogue detail sheet shows the internal source lesson number (`#\(entry.passage.lesson)`), and the level label is derived from that id (`lesson >= 2000`).
   - Scenario: Opening a dialogue's sheet shows e.g. '#2143 · 1:12 · 9 lines · Upper int. · …'. That is an internal id shown to the learner, which goes against the settled 'no internal machinery' rule. The 'Upper int.' label is also a magic threshold on the id, not data.
   - Fix: Drop the `#lesson ·` prefix. Carry the level as a field on Passage, set in the pipeline, instead of deriving it from the id.

24. **[low/ui] PassageScreen.swift:135** Two `meta(_ passage:)` helpers format the same passage facts differently: '72s · 9 lines · A, B' in PassageScreen, '1:12 · 9 lines · Upper int. · A, B' in DialoguePicker.
   - Scenario: The same dialogue's length reads '1:12' on the picker card and '72s' once it is opened. The duplicated logic will keep drifting.
   - Fix: Add one `Passage.metaLine(speakers:level:)` (or an extension in DialoguePicker.swift) used by both, and pick one duration format.


## Skipped by the fixer

- 4 (part): unknown-value fallback case for AtomKind: AtomKind is CaseIterable, and an extra case would likely reach the model schema (prompt text) and the label switches. Decoding element by element already limits a renamed kind to losing only the elements that use it.
- 7: remove progress.xp/streak/lastPractisedOn, or route drill outcomes into Progress: Removing the fields changes the persisted Progress format: older builds decode xp/streak with `decode` and would lose the whole Progress. Routing drill verdicts into retrieval or reach changes learner-visible point states, which is a product decision.
- 13: tools/check_book.py tile-multiset check and the fr.q.future.37 accept: Python tool plus curriculum JSON; this pass was limited to Swift and tests, and Curriculum/ has someone else's uncommitted changes.
- 23 (part): sending a 401 upload rejection to Worker.revoked(): revoked() deletes the stored invite, but the app's `invited` state only flips through the foreground check, which then finds no invite and returns false, so the learner would be stuck with a dead invite. 401 is backed off like other transient failures instead.
- 26: show or drop GradingJob.error: Showing a reason changes what the learner sees, and dropping the field changes the persisted job format.
- 36 (part): narrower representable or subclass instead of the UINavigationController extension: The extension was moved and documented rather than replaced; a narrower approach needs checking on a device for every navigation stack.

## Reviewer notes

### state

State and data-model cohesion, sketch of a per-point learner record.

What evidence is written today, and where:
1. Produce/translate review landing: Store.land, then record(for:) and reached().
   - Progress.structures[point].attempts/successes: from the prompt's pointID and from review.usedPoints, with success meaning the whole sentence had no problems.
   - Progress.words: words produced, via the Lexicon.
   - Progress.retrieved/missed on revisited subjects: string match.
   - Progress.saw on every problem atom.
   - ScoreLog: the turn score.
   - The Review itself is stored inside the archived Session, trimmed to 120 sessions. It is the only place the findings, their fix text and the learner's sentence survive.
2. Lesson interaction: open(atom) (Progress.opened, visits), classify (slip/gap), setReturn (bringBack/leaveOut), recordDrill (xp only, dead), respeaks (nothing recorded).
3. Listen clips: gradeNow, which does record(for:) without words. Dialogues: finishPassage writes PassageState.heard (Heard: right/asked/followed), a synthetic listen Turn in past, and Progress.saw on comprehension (line) and wordChoice (tapped word) atoms. PassageRun.tapped and answers persist only until the run is done.
4. Quizzes: QuizLog.entries[entryID] (recent[8], held, known, last) via finish/recordEndless, and QuizLog.plans[lang|plan] scores. Entry → point goes through Chapter.Entry.point.
5. Vocab drill and word decks: QuizLog.entries['vocab.<lang>.<w>'], markKnown, markConcept across languages, and conceptEdits.
6. Textbook: suggestions (ask answers naming a point), bank pins (BankEntry.pointID), StretchRequest.

Proposed record: one LearnerRecord per (language, pointID). Findings with no point stay keyed by atom id, linked to a point once the review names one; Tutor.swift:223 is the blocker today.
- production: a chronological list of uses, each {turnID, day, mode, source: prompted|stretch|usedTag|revisit, verdict: clean|slip|broke, atomIDs, sentence, fix?}, capped at about 20 per point. It replaces StructureUse counts and Textbook.uses/noted scanning the archive, and survives archive trimming.
- schedule: the current Encounter fields (stage, dueAt, cleanRuns, standing, knowledge, visits, sightings, lastChecked day), held per point, with a child map for atom-level encounters.
- recognition: quiz results per book entry {recent[], held, known, last}, and vocab/word-deck rows for the point's words.
- listening: gist misses and tapped words per passage line, linked to points where a line's grammar is tagged, with their own channel and interval (Shelf), never woven into production.
- learner: pinned, requested-as-stretch, suggestions (question and context), lessons opened, drill and respeak outcomes per rung.
- derived (not stored): standing = never/tried/holding/solid. Production alone gives solid; recognition caps at holding. Plus a slipping flag, last-seen, a next-due date, and the 'why' line.

How the day plan would read it:
- stretch = points at or below the level with production.uses empty, weighted up when recognition is holding (they know it but never say it).
- back = points or atoms with schedule.dueAt <= today, at most one retrieval per day each, deduplicated across translate and produce.
- words = deck-holding words never produced, then deck-missed words.
- the record cells = derived standing.
- levelOffer = the production verdicts in the window, never listen.

Writes funnel through one Store.ingest(evidence:) called from land, finishPassage, the quiz finish/endless paths, markConcept and drills. That is the single place to read results, and the per-point page becomes a lookup instead of scans across past, Progress, QuizLog, suggestions and bank.

Migration: build the records once from Progress, QuizLog and the archive while it still exists. Archive turns older than 120 sessions are already lost.

Other observations:
- Store.swift mixes about eight concerns (session runtime, grading pipeline, dialogues, lessons, textbook, quizzes and top-ups, words, history, span and diff utilities). The nonisolated static span/divergence/tokens code (about 400 lines) could move to its own file with no behaviour change.
- The pump's local `job` copies are written back with `put` after awaits. Today only `readAt` and `error` can race, and only on done jobs, so I did not report it, but it will bite if more fields get mutated from the UI.
- Encounter construction is copied four times in Progress (opened, classify, saw, bringBack); a `fresh(atom:)` helper would remove that.

### grading

The overall shape is sound. Ingestion is idempotent: ingest and gradeMissing skip a turn that already has a review. The job id makes resends from the same edge return the same batch. Refusals, malformed JSON and score-0-with-no-findings replies all fall through to the single automatic live retry.

The weak spot is the seam between the app's direct-grading path and the worker's. The 20-minute switch is counted in two places that can disagree (sentAt in the app, `since` in the worker, and `since` resets on a late /watch). The direct claim has no timeout. And the app reads 'no direct results' as permission to read a cancelled batch. Findings 1, 2 and 6 together decide whether a stalled batch costs 1x, 2x or never finishes. They are worth fixing together, ideally with a stalled-batch test against a dev worker. I'm less sure of the exact cron wall-time cap than of the missing reclaim; the reclaim is needed either way.

Not flagged:
- Pronunciation and Speech look fine: the Azure config goes in a base64 header, and nil is returned on failure.
- Push token handling and Tap matching look fine.
- Anthropic.reply doesn't check stop_reason "max_tokens". At 32k it is unlikely to matter, but truncated output shows up as a 'broken JSON' failure and is retried at the same cap.
- The stale-copy put(job) after awaits in pump can briefly overwrite `uploading`; reconcileUploads repairs it.
- The `/anthropic` proxy lets any invite read any batch id. That's acceptable for friends-only testers.

### ui

I read all of UI/**, plus Store and Services where needed to confirm findings. Ledger.swift and Theme.swift are solid and most screens use them well. The main problems are a handful of state bugs in secondary flows (drills, word deck, passages) and some inline re-implementations. Smaller observations that did not make the list:

- **Hairline boxes:** several hand-made hairline boxes use `.stroke` where Panel uses `.strokeBorder`. Locations: SettingsScreen 57–59 and 101–104 (these copy Panel), PassageScreen 86, FormulaView 173, TransformQuiz 451–453. `.stroke` draws half the line outside the frame, so neighbouring boxes double up or get clipped.
- **Duplicated pieces:**
  - PassageScreen.meter (357) repeats SquareProgress with a sunk background.
  - ReviewScreen.specimenRow (144–147) repeats LedgerRow's double red margin; a `MarginRule` view would cover both.
  - The tab bar caret in AppShell 167 repeats IBeam.
  - BookParts' `Ticks` dashed cell repeats StateCell(.never).
  - `EntryState.label` ('NEVER USED') and `LedgerState.name` ('NEVER') name the same states differently.
- **Colour duplication:** Theme.install (178–180) repeats the ground/seam/ink hex values instead of reading the `C` tokens.
- **Inconsistent thresholds:**
  - History colours a session average `< 60` as bad, while Theme.band uses 80/50.
  - CardQuiz.face checks for CJK over 0x3000–0x9FFF, ChineseInput over 0x4E00–0x9FFF.
- **Accessibility:**
  - The gloss bar's '×' close button in PassageScreen (295) has no accessibilityLabel.
  - `Busy(text: "")` in ChapterScreen and EntryScreen gives the Ticker an empty label instead of 'Working'.
  - StagedAtomRow and DayFindingRow add the `.isButton` trait to a container that has buttons inside it, without combining children.
- **Text fields:** the retype field in AllLanguages sets autocorrect and capitalisation by hand instead of using `.targetLanguageInput()`. InviteScreen's CodeField coordinator holds a `let parent` that is never refreshed in updateUIView; ChineseField does refresh its copy.
- **Dead aliases:** MainButton and QuizCheckButton are legacy wrappers around ActionKey and could be inlined.
- **Lazy layout:** the Book/Chapter/Entry screens each recompute `store.bookIndex` on every body. That is reasonable today, but it is the first thing to cache if the Book tab feels slow.

### secondary

How quiz results could reach the shared learner record: today it flows one way. Quizzes read production (pointSolid) through Store.state(of:), but nothing in DayPlan, Progress or the Today screens reads quizLog. The only other consumers are history (QuizLog.plans) and activity. Three ways in, cheapest first. (1) Make Store.state(of:) the single combined reader: production standing plus quiz standing, solid only from production, as in finding 2. Then the Book, quiz weighting and recommend all see the same record. (2) Feed quiz slips on an entry that has a point into DayPlan as a light review signal, e.g. when picking the stretch or the produce seed. This keeps the settled rule that quizzes reach at most holding, and never writes Progress reach. (3) Endless rounds and the concept deck write no PlanRecord, so HistoryDay never shows them, while a standard round abandoned at 19/20 records its entries but marks no activity (finish, Store.swift:2498, versus recordEndless and markConcept, which mark activity on every answer). Pick one rule for what counts as a quiz day.

Other observations:
- The format rules are kept by hand in three places: QuizFormat.rules, check_book.py RULES, and the TopUp.system prose, which still calls spot-it's steps '1' and '2' while Quiz.swift calls them 0 and 1. A JSON rules file read by both Swift and the script would remove one copy.
- check_book.py does not validate vocab-*.json or concepts.json. I checked by hand: every concept word is in its vocab list, with no duplicate words, no empty glosses and no skips. A small check would keep it that way when build_concepts.py is rerun.
- The why-length warning tests `> 4` words but its message says 'longer than 3'.
- Every word deck shares one schedule through 'vocab.<lang>.<w>' entries, and the concept deck, WORDS rounds and endless words all read it; that holds up. Retyped concept words get their own entry, which wordsDue never counts. That is acceptable, but it means conceptsDue and wordsDue can disagree.
- Level floor and stretch cap in assemble look right. With count < 10, cap is 0, so level+1 entries only fill gaps; that is how the doc describes it.
- The build and transform checks handle CJK spacing, elision, hyphens, French NBSP and guillemets correctly. Apart from the U+2018 and full-width cases above, I found no failing case in the shipped data.
- The Lexicon ge- stripping over-matches a little ('gegen' gives the key 'gen'), as its comments document; not worth changing.


## Content flags

### mandarin
- Levels that look too high for HSK 3.0 (left as they are; your call): wulun-ruhe 无论如何 L9, guanjian-zaiyu 关键在于 L9, bujin-gengshi 不仅…更是… L9. These are common upper-intermediate items, closer to L5–6.
- fouze 否则 is marked use=written, but it is also common in speech. Arguably it should be 'both'.
- subject-in-clause: Mandarin drops subjects freely, so the point's premise ('Clauses keep their subject') is shaky. The example is fixed, but the point itself may be worth rethinking.
- check_book.py prints a warning (it still passes) on zh.linked.yifangmian: its reading 'yì fāngmiàn … lìng yì fāngmiàn' is longer than 3 words.
- git diff also shows book-french.json and grammar-french.json as changed. I did not touch them; another agent probably edited them at the same time.

### german
- Quiz de.q.pointers.29 in quiz-german.json still reads 'Beide Angebote sind gut, ＿ ist allerdings günstiger.' (answer dieses). The form is right, but it is unclear which offer is meant. I left it alone because quiz files were outside this audit. Suggest rewording it to the 'das von gestern' pattern, as de.q.pointers.30 already does.
- Several book entries have no point: the accusative prepositions durch/für/gegen/ohne/um, de.case.die/das/plural/ein/eine, de.connectors.sonst and sondern, and de.relative.was. No grammar point covers accusative prepositions, sondern or 'alles, was'. Do you want new points added? That would mean new ids, so I didn't add any.
- de.genitive.trotz is filed under group 'cause', but trotz expresses concession, not cause. Fixing it means adding a one-entry group, which may look odd in the Book layout, so I left it.
- Several book entries sit a level or two below their point: in/ins and the Wechselpräpositionen at L1 against two-way-prep at L2, haette/waere at L2 against konjunktiv-ii at L3, de.genitive.waehrend at L3 against temporal-nominal at L4, de.konjunktiv-ii.wuesste at L4 against strong-konjunktiv-ii at L6. Each is defensible for that one item, so I didn't change them.
- Level moves here (comparison 1→2, superlative 3→2, man 3→1, du-ihr-sie 2→1) change where these points come up for learners already in progress. Ids are unchanged, so no history is lost.

### french
- ne-retention (grammar) and fr.formal.ne-writing (Book) still teach keeping ne in formal writing. I softened the instruction so it no longer calls a dropped ne wrong. Simon may want to confirm the grader never penalises a missing ne even for this written point.
- Levels left as they are but debatable against the CECR référentiel: clitic-clusters (L4) is B1 in several syllabi; y-en (L3) and negation-frames (L3) are often A2; conditionnel-passe-regret (L4) is often B1. Not moved.
- fr.si.et-que: the head and reading use si … et que, but the example uses bien que … et que. That fits the point (any conjunction) but looks mismatched inside the Si chapter.
- fr.voice.se-passive (ce vin se boit jeune) is a pronominal passive filed under on-for-passive. No closer point exists. A dedicated point would be needed to file it exactly.
- A warning that was there before my edits remains: the 'why' on rule.fr.gender.x-age in rules-french.json is longer than 3 words. Not in scope, not changed.
