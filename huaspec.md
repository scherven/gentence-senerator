# Huá (滑): a Chinese reading layer for Reddit

A Safari Web Extension for iOS that weaves Chinese into Reddit while you scroll. The level matches what you know (HSK 2–3 to start). It logs what you read so it can hand you more Chinese over time.

Mockups: https://claude.ai/artifact/Gv1gPxewj41HKzJuLMR9Ti

## Decisions

| Area | Decision |
|---|---|
| Platform | Safari Web Extension, iOS first. It ships as a target inside the gentence-senerator Xcode project, with the display name "Huá". |
| Sites | reddit.com only in v1. X/Twitter comes later. |
| Where it runs | All of reddit.com. A toggle in the toolbar popup turns it off. |
| What gets translated | Post titles (in the feed and on post pages) and post bodies. Never comments. |
| Reading modes | Side by side, Woven and Chinese first. Structure is shown as the hybrid view (below). |
| Structure view | The hybrid: the "move" animation (English order, then Chinese order, then Chinese), with each chunk labelled by its slot (Link, Who, When, How, Do, What). It's skipped for sentences where nothing moves. It opens from a pattern pill, and is also available as a mode. |
| Tones | Pinyin with tone marks (ā á ǎ à). No tone colors. |
| Pinyin | Fades out as a word climbs the ladder (see below). |
| Budget | $5 a month, which is $0.16 a day. It's split 30% for feed titles and 70% for opened posts. A bar in the toolbar popup fills up as it's spent. |
| Over budget | Translations already made stay cached. New text falls back to offline word swaps using words already in the log. There's no structure view or pattern detection until the budget resets. |
| Starting vocab | HSK 3.0 bands 1–2 start as known, band 3 starts as new, and anything above that stays English. The band list is `Curriculum/words-mandarin.json` (MIT, from Pleco). |
| "Seen" | A word counts as seen only inside a post you opened (a `/comments/` page), at most once per post. Feed titles show Chinese but don't count. |
| Promotion | Automatic: a word moves up after enough sightings without a tap. |
| Demotion | A tap drops the word one rung. |
| Log | Words and sentences, stored on the phone. No subreddit, URL or author. |
| Accuracy | Every response is validated on the phone and anything broken is dropped. Long-press any translated sentence to flag it, and the flag goes to the worker. |
| Standalone | No sync with the app in v1. The log lives in extension storage, laid out so an App Group can expose it to the app later. |

## The word ladder

Each word has a rung from 0 to 3. Sightings count only in opened posts.

| Rung | How it appears in Woven mode | Moves up after |
|---|---|---|
| 0 · new | `friends 朋友` with pinyin. The English comes first and the Chinese sits beside it. | 4 sightings with no taps |
| 1 · learning | `朋友 (friends)` with pinyin. The Chinese takes the slot and the English shrinks to a hint. | 10 sightings with no taps |
| 2 · familiar | `朋友` with pinyin and no hint | 20 sightings with no taps |
| 3 · known | `朋友` with no pinyin. The word can also appear in fully Chinese sentences. | — |

- A tap (to open the word card) drops the word one rung and resets its sightings count at that rung.
- Seeding: HSK bands 1–2 start at rung 2 and band 3 starts at rung 0.
- Woven mode shows rungs 1–3 as Chinese. A rung 0 word appears at most twice per post, so new words trickle in.
- The density slider (Light, Medium, Heavy) sets the lowest rung shown in Chinese. Heavy also lets rung 0 words in.

## Architecture

```
reddit.com page ──content script──▶ background script ──▶ Cloudflare worker ──▶ Claude API
     ▲  render, taps, dwell              │  queue, cache, budget          │  /translate, /flag
     └──────────── toolbar popup ◀───────┴── browser.storage.local (log)  └─ KV: cache, spend, flags
```

- **Content script:** finds post titles and bodies on new Reddit (`shreddit-post`, which uses shadow DOM, plus the title and body slots) and on old.reddit. It watches with a `MutationObserver` for infinite scroll, and uses an `IntersectionObserver` to queue text as it nears the viewport. It renders `<ruby>` pinyin, the woven words, pattern pills, the word card and the structure popup. It records sightings on `/comments/` pages and records taps.
- **Background script:** batches queued items (up to about 8 per request), checks the local cache, calls the worker, validates the response and writes the log.
- **Toolbar popup:** the on/off toggle, the mode, the density slider, pinyin on/off and the budget bar (today's spend against $0.16, split into the title and body portions).
- **Worker:** new routes on the existing `gentence-grader` worker, using the same `x-watch-secret` pattern. The secret ships inside the extension, which is fine for a single-user app, and the worker's spend cap is the real guard.

## Worker contract

### `POST /translate`

Request:

```json
{ "items": [ { "id": "t3_abc:title", "kind": "title", "text": "Sphinx's approach" },
             { "id": "t3_abc:body",  "kind": "body",  "text": "I saw the 17lands data, ..." } ],
  "level": "hsk2-3" }
```

Response:

```json
{ "results": { "t3_abc:body": { "sentences": [ /* Sentence */ ] } },
  "skipped": ["t3_abc:title"],
  "spend": { "today": 0.071, "limit": 0.16, "titles": 0.020, "bodies": 0.051 } }
```

- **`skipped`:** items not translated because that portion of the budget is spent. The client falls back to offline swaps for these.
- **Cache:** results are cached in KV under `tr:<sha256(promptVersion + model + text)>`. A cache hit costs nothing and doesn't touch the budget.
- **Spend:** the worker computes spend from `usage` multiplied by the model's prices and adds it to `spend:<YYYY-MM-DD>`. That key is the authoritative cap.
- **KV writes:** the free tier allows 1,000 KV writes a day. Batching items and writing one spend update per request keeps us well under it. If that stops being enough, move the spend counter to a Durable Object.
- **Request shape:** one Messages API call per batch, with structured output (`output_config.format`) using the schema below. The system prompt is frozen and cached, and posts go after it.

### `POST /flag`

```json
{ "cacheKey": "tr:…", "sentence": 2, "note": "optional" }
```

This stores `flag:<ts>` and deletes the cache entry, so the text is translated again the next time it's seen. Flags are used to tune the prompt.

### Sentence schema

```json
{
  "en": "Its ALSA is 3 points higher, so maybe people are getting it for free?",
  "chunks": [
    { "id": "a", "en": "Its ALSA", "zh": "它的ALSA", "py": "tā de ALSA", "role": "subj", "slot": "Who" },
    { "id": "i", "en": "is", "zh": "", "py": "", "role": "other", "slot": null },
    { "id": "d", "en": "higher", "zh": "高", "py": "gāo", "role": "verb", "slot": "Do" },
    { "id": "p", "en": ",", "zh": "，", "punct": true }
  ],
  "enOrder": ["a", "i", "b", "d", "p", "…"],
  "zhOrder": ["a", "i", "d", "b", "p", "…"],
  "moved": ["b", "f"],
  "pattern": { "id": "how-before-verb", "name": "How goes before the verb", "hz": "", "formula": "Who + How + Do", "note": "…" },
  "words": [ { "hz": "免费", "py": "miǎn fèi", "gloss": "free of charge", "hsk": 4 } ]
}
```

- `role` is one of `subj`, `verb`, `obj`, `time`, `link` or `other`, and sets the chunk's color.
- `slot` is one of `Link`, `Who`, `When`, `How`, `Do`, `What` or `null`.
- An empty `zh` means English has a word that Chinese drops. If an id is missing from `enOrder`, the chunk exists only in Chinese (for example 所以).
- If `moved` is empty, the client skips the structure view.
- Names and jargon (17lands, ALSA, card names) pass through untranslated.
- `pattern.id` comes from a fixed list kept in the prompt, so the log can count patterns.

### Validation on the phone

A sentence is dropped, and that text stays English, if any of these checks fail:

- The `zh` values joined in `zhOrder` don't reconstruct the sentence.
- `enOrder` and `zhOrder` reference ids that don't exist.
- A slot or role isn't in the allowed set.
- The number of pinyin syllables doesn't match the number of hanzi.

## Offline fallback

When the budget is spent, Woven mode swaps English words for Chinese using only words already in the log, because each logged word carries the gloss it was learned with. A swap happens only when a gloss maps to a single logged word, so "bank" is never guessed. There's no structure view, no pattern pills and no logging of sightings.

## Storage (`browser.storage.local`)

```
words:     { "<hanzi>": { rung, seenAtRung, seenTotal, taps, lastSeen, py, gloss, hsk } }
sentences: ring buffer, max 2,000: { zh, en, patternId, ts }   (no source)
patterns:  { "<patternId>": { count, lastSeen } }
days:      { "YYYY-MM-DD": { seen, taps, newWords } }
settings:  { enabled, mode, density, pinyin }
```

The "your feed examples" section of the pattern popup draws on `sentences`, filtered by `patternId`.

## Model and cost

The prompt is about 2,000 tokens, cached. A batch of posts is about 600 tokens in and about 800 tokens of JSON out. These are rough per-post estimates to check against real `usage`:

| Model | ≈ cost per post | Posts per $0.16 day |
|---|---|---|
| `claude-opus-5-5` ($4 / $20 per MTok) | ≈ $0.018 | ≈ 9 |
| `claude-sonnet-5-5` ($2 / $10) | ≈ $0.009 | ≈ 18 |
| `claude-haiku-5-5` ($0.10 / $0.50) | ≈ $0.0005 | ≈ 300 |

**Open: which model.** The budget only covers real scrolling with Haiku. Plan: start on Haiku at low effort, check quality on the flagged sentences, and make the model a worker variable so it can be changed without shipping a new build.

## Build plan

1. Worker: `/translate` with caching, the spend cap, the schema and the prompt, plus `/flag`. Test it with saved r/lrcast posts.
2. Extension skeleton: the Safari Web Extension target, manifest v3, toolbar popup with the toggle and budget bar.
3. Content script on old.reddit first (plain HTML), then new Reddit (shadow DOM).
4. Woven mode, the word card and the ladder logic, including seeding from `words-mandarin.json`.
5. Side by side and Chinese first modes, pattern pills and the hybrid structure popup.
6. Validation, long-press flagging and the offline fallback.
7. Log views in the popup: words to watch and patterns met.

## Still open

- Which model (see above).
- Old Reddit vs. new Reddit on iOS Safari: which one do you actually use? The content script gets built for that one first.
