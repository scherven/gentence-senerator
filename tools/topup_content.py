#!/usr/bin/env python3
"""Write new quiz items into Curriculum/quiz-<lang>.json for one book chapter
or entry, the way the app tops up a chapter at runtime (Core/TopUp.swift).

Same contract as the app: one call writes (TopUp.system, TopUp.schema,
TopUp.request), the drafts are kept by TopUp.keep's rules (entry in scope,
allowed format, the format's rules, under 0.7 bigram similarity to anything
used), a second call checks them (TopUp.checkSystem) and what it fails is
dropped. Then every survivor must pass tools/audit_content.py's item checks
and tools/check_book.py's format rules before it is appended. Model
claude-sonnet-5-5 (Anthropic.topUpModel), effort medium.

    python3 tools/topup_content.py german --chapter de.verb-prep --dry-run
    python3 tools/topup_content.py mandarin --entry zh.measure.tai --batches 2

Ids are <code>.q.top.<chapter slug>.<n>, never one already in quiz-, gen- or
rules-<lang>.json nor one this tool has handed out before, even for an item
later rejected. Progress is written to tools/.topup/<lang>.<target>.json
after every call and step, so Ctrl-C or a failure loses at most the call in
flight; rerunning the same command resumes. The key is read from
secrets/key.swift the way tools/prompt_variety.py reads it. --dry-run prints
the first request and touches nothing: no key, no network, no files.
"""
import argparse, json, os, pathlib, random, re, sys, time, unicodedata
import urllib.error, urllib.request

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import audit_content  # noqa: E402
import check_book     # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
CUR = ROOT / "gentence-senerator/gentence-senerator/Curriculum"
KEYFILE = ROOT / "secrets/key.swift"
STATE_DIR = pathlib.Path(__file__).resolve().parent / ".topup"
MODEL = "claude-sonnet-5-5"
CODE = {"mandarin": "zh", "german": "de", "french": "fr"}

# --- Core/TopUp.swift, verbatim ---------------------------------------------

BATCH = 20
SAME_AT = 0.7

SYSTEM = """You write quiz items for a language-learning app. Each item tests one rule \
from a textbook chapter, given as entries with ids. Write the items asked \
for as JSON matching the schema.

Formats, and the fields each uses (leave the rest empty):
- pick-one: `prompt` is a sentence with one ＿ gap; one step, 3–4 options.
- flip: `prompt` with one ＿ gap; one step, exactly 2 options.
- two-step: `prompt` with ＿ gaps; two steps, each 2–5 options, each step \
with a short `prompt` naming what it asks ("auxiliary", "ending").
- spot-it: step 1's options are the sentence's tokens and its answer is the \
wrong token; step 2 offers fixes and its answer is the right one.
- build: `tiles` are the sentence's pieces in the right order; `decoys` are \
2–3 wrong pieces; `accept` lists other correct orders, tiles joined by \
single spaces.
- transform: `prompt` is a sentence, `task` the instruction ("→ Perfekt"), \
`accept` every correct rewrite.
- sort: 4–12 steps, each step's `prompt` an item, the same 2–4 buckets as \
options on every step.

Every item:
- has exactly one defensible answer. No distractor a native speaker would \
also accept, including colloquial usage.
- is a natural sentence at the learner's level, about everyday life, \
varied in vocabulary and situation.
- is new: never reuse, translate back or lightly edit a sentence from the \
"already used" list.
- has `gloss`: the English of the sentence, and `why`: the rule in three \
words at most ("warten auf", "机器 → 台")."""

_STEP = {"type": "object", "additionalProperties": False,
         "properties": {"prompt": {"type": "string"},
                        "options": {"type": "array", "items": {"type": "string"}},
                        "answer": {"type": "integer"}},
         "required": ["prompt", "options", "answer"]}
_STRINGS = {"type": "array", "items": {"type": "string"}}
SCHEMA = {"type": "object", "additionalProperties": False,
          "properties": {"items": {"type": "array", "items": {
              "type": "object", "additionalProperties": False,
              "properties": {"entry": {"type": "string"}, "format": {"type": "string"},
                             "prompt": {"type": "string"}, "gloss": {"type": "string"},
                             "task": {"type": "string"}, "why": {"type": "string"},
                             "steps": {"type": "array", "items": _STEP},
                             "tiles": _STRINGS, "decoys": _STRINGS, "accept": _STRINGS},
              "required": ["entry", "format", "prompt", "gloss", "task", "why",
                           "steps", "tiles", "decoys", "accept"]}}},
          "required": ["items"]}

CHECK_SYSTEM = ("You check quiz items written for a language learner. For each numbered "
                "item, decide whether the marked answer is right and is the only answer a "
                "native speaker would accept, colloquial usage included, and whether the "
                "sentence is natural. List the numbers of every item that fails.")
CHECK_SCHEMA = {"type": "object", "additionalProperties": False,
                "properties": {"fail": {"type": "array", "items": {"type": "integer"}}},
                "required": ["fail"]}

ITEM_KEYS = ("id", "entry", "format", "prompt", "gloss", "task", "speak", "why",
             "steps", "tiles", "decoys", "accept")


def formats(chapter):
    """TopUp.formats: tone-tap comes from the vocab lists."""
    return [f for f in chapter.get("formats", []) if f != "tone-tap"]


def level_label(lang, n):
    """LanguagePack.level."""
    if lang == "mandarin":
        return f"HSK {min(max(n, 1), 9)}"
    return ["A1", "A2", "B1", "B2", "C1", "C2"][min(max(n - 1, 0), 5)]


def swift_json(item):
    """An item as JSONEncoder writes it: every array, nils left out, `/` escaped."""
    full = {k: item.get(k) for k in ITEM_KEYS}
    for k in ("steps", "tiles", "decoys", "accept"):
        full[k] = full[k] or []
    full = {k: v for k, v in full.items() if v is not None}
    return json.dumps(full, ensure_ascii=False, separators=(",", ":")).replace("/", "\\/")


def request(chapter, level, examples, used, count=BATCH):
    """TopUp.request."""
    entries = [" | ".join(str(e[k]) for k in ("id", "head", "gloss", "group", "tag", "example")
                          if e.get(k) is not None) for e in chapter["entries"]]
    shown = [swift_json(x) for x in examples]
    return (f"Learner's level: {level}\n"
            f"Chapter: {chapter['name']}\n"
            f"Entries (id | head | gloss | group | tag | example):\n"
            + "\n".join(entries) + "\n\n"
            f"Formats allowed: {', '.join(formats(chapter))}\n"
            f"Write {count} items, spread over the entries and formats.\n\n"
            "Examples of the style:\n" + "\n".join(shown) + "\n\n"
            "Already used (do not reuse):\n" + "\n".join(used))


def expected(item):
    """QuizRound.expected."""
    f = item["format"]
    if f == "build":
        return [join(item.get("tiles", []))]
    if f in ("transform", "card"):
        return [(item.get("accept") or [""])[0]]
    return [s["options"][s["answer"]] if 0 <= s["answer"] < len(s["options"]) else ""
            for s in item.get("steps", [])]


def check_request(items):
    """TopUp.checkRequest."""
    lines = []
    for i, it in enumerate(items):
        options = " ; ".join(", ".join(s["options"]) for s in it.get("steps", []))
        lines.append(f"{i}. [{it['format']}] {it.get('prompt') or ' '.join(it.get('tiles', []))}"
                     + (f" ({it['task']})" if it.get("task") else "")
                     + (f" — options: {options}" if options else "")
                     + f" — answer: {' / '.join(expected(it))}")
    return "\n".join(lines)


# --- QuizRound.normalise / join, for the near-duplicate test ----------------

def is_cjk(c):
    v = ord(c)
    return 0x3000 <= v <= 0x9FFF or 0xFF00 <= v <= 0xFFEF


def is_punct(c):
    return unicodedata.category(c).startswith("P")


def normalise(s):
    t = unicodedata.normalize("NFKC", s).lower()
    for q in ("’", "‘", "ʼ", "`"):
        t = t.replace(q, "'")
    t = "".join(c if c in "'-" or not is_punct(c) else " " for c in t)
    out = ""
    for w in t.split():
        if out and not is_cjk(out[-1]) and not is_cjk(w[0]):
            out += " "
        out += w
    while out and (is_punct(out[-1]) or out[-1] in " \t"):
        out = out[:-1]
    return out


def separator(before, after):
    if not before or not after or is_cjk(before[-1]) or is_cjk(after[0]) or before[-1] in "'’-":
        return ""
    return " "


def join(tiles):
    out = ""
    for t in tiles:
        out += separator(out, t) + t
    return out


def text(item):
    return item.get("prompt") or join(item.get("tiles", []))


def bigrams(s):
    chars = normalise(s.replace("＿", " "))
    if len(chars) <= 1:
        return {chars: 1} if chars else {}
    out = {}
    for i in range(len(chars) - 1):
        out[chars[i:i + 2]] = out.get(chars[i:i + 2], 0) + 1
    return out


def similarity(a, b):
    total = sum(a.values()) + sum(b.values())
    if not total:
        return 0.0
    return 2 * sum(min(v, b.get(k, 0)) for k, v in a.items()) / total


def keep(drafts, chapter, used, ids):
    """TopUp.keep, handing out `ids` (a callable) instead of a timestamp."""
    entries = {e["id"] for e in chapter["entries"]}
    allowed = set(formats(chapter))
    seen = [bigrams(u) for u in used]
    out, dropped = [], []

    def blank(s):
        return None if s is None or not s.strip() else s

    for d in drafts:
        if d.get("entry") not in entries or d.get("format") not in allowed:
            dropped.append(("scope", d)); continue
        item = {"id": None, "entry": d["entry"], "format": d["format"],
                "prompt": blank(d.get("prompt")), "gloss": blank(d.get("gloss")),
                "task": blank(d.get("task")), "why": blank(d.get("why")),
                "steps": [{"prompt": blank(s.get("prompt")), "options": s.get("options", []),
                           "answer": s.get("answer")} for s in d.get("steps", [])],
                "tiles": d.get("tiles", []), "decoys": d.get("decoys", []),
                "accept": d.get("accept", [])}
        errs = []
        check_book.check_item(dict(item, id="draft"), {item["entry"]: {}}, set(), errs, [])
        if errs:
            dropped.append(("rules", d)); continue
        grams = bigrams(text(item))
        if any(similarity(grams, g) >= SAME_AT for g in seen):
            dropped.append(("similar", d)); continue
        seen.append(grams)
        item["id"] = ids()
        out.append(tidy(item))
    return out, dropped


def tidy(item):
    """In the file's shape: its key order, empty fields left out."""
    out = {}
    for k in ITEM_KEYS:
        v = item.get(k)
        if k == "steps" and v:
            v = [{**({"prompt": s["prompt"]} if s.get("prompt") else {}),
                  "options": s["options"], "answer": s["answer"]} for s in v]
        if v not in (None, [], ""):
            out[k] = v
    return out


# --- I/O ----------------------------------------------------------------------

def load_key():
    """As tools/prompt_variety.py does, from secrets/key.swift."""
    txt = KEYFILE.read_text()
    m = re.search(r'anthropicKey\s*[:=]\s*"([^"]+)"', txt) or re.search(r'"(sk-[^"]+)"', txt)
    if not m:
        sys.exit(f"could not parse an API key from {KEYFILE}")
    return m.group(1)


def body(system, user, schema, max_tokens):
    """Anthropic.params: cached system, schema-constrained, effort medium."""
    return {"model": MODEL, "max_tokens": max_tokens,
            "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
            "messages": [{"role": "user", "content": user}],
            "output_config": {"effort": "medium", "format": {"type": "json_schema", "schema": schema}},
            "fallbacks": "default"}


TRANSIENT = {429, 500, 502, 503, 529}


def call(key, payload):
    req = urllib.request.Request("https://api.anthropic.com/v1/messages",
                                 data=json.dumps(payload).encode(), method="POST")
    for h, v in [("x-api-key", key), ("anthropic-version", "2023-06-01"),
                 ("anthropic-beta", "server-side-fallback-2026-07-01"),
                 ("content-type", "application/json")]:
        req.add_header(h, v)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=600) as r:
                obj = json.loads(r.read())
            if obj.get("stop_reason") == "refusal":
                raise RuntimeError("refused: " + str((obj.get("stop_details") or {}).get("explanation")))
            return json.loads("".join(b.get("text", "") for b in obj.get("content", [])
                                      if b.get("type") == "text"))
        except urllib.error.HTTPError as e:
            if e.code in TRANSIENT and attempt < 3:
                time.sleep(float(e.headers.get("retry-after") or 3 * (attempt + 1)))
                continue
            raise RuntimeError(f"HTTP {e.code}: {e.read().decode()[:300]}")
        except (urllib.error.URLError, TimeoutError):
            if attempt < 3:
                time.sleep(2 * (attempt + 1)); continue
            raise
    raise RuntimeError("exhausted")


def write_atomic(path, data):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(data, encoding="utf-8")
    os.replace(tmp, path)


def dump_items(items):
    """quiz-<lang>.json's own formatting, byte for byte."""
    return json.dumps(items, ensure_ascii=False, indent=1) + "\n"


def load_items(lang, kind):
    p = CUR / f"{kind}-{lang}.json"
    return json.loads(p.read_text(encoding="utf-8")) if p.exists() else []


# --- main -----------------------------------------------------------------------

def scope(lang, chapter_id, entry_id):
    book = json.loads((CUR / f"book-{lang}.json").read_text(encoding="utf-8"))
    for ch in book["chapters"]:
        if chapter_id and ch["id"] == chapter_id:
            return ch, ch
        for e in ch["entries"]:
            if entry_id and e["id"] == entry_id:
                return ch, dict(ch, entries=[e])
    sys.exit(f"no {'chapter ' + chapter_id if chapter_id else 'entry ' + entry_id} in book-{lang}.json")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("lang", choices=list(CODE))
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--chapter")
    g.add_argument("--entry")
    ap.add_argument("--batches", type=int, default=1, help="write calls to make in all (default 1)")
    ap.add_argument("--count", type=int, default=BATCH, help=f"items asked for per call (default {BATCH})")
    ap.add_argument("--level", type=int, help="learner level; default the highest entry level in scope")
    ap.add_argument("--seed", type=int, default=0, help="picks the style examples")
    ap.add_argument("--dry-run", action="store_true", help="print the first request; no key, network or files")
    args = ap.parse_args()

    lang, code = args.lang, CODE[args.lang]
    chapter, target = scope(lang, args.chapter, args.entry)
    if not formats(chapter):
        sys.exit(f"{chapter['id']} has no format the model may write")
    level_n = args.level or max((e.get("level") or 1) for e in target["entries"])
    level = level_label(lang, level_n)
    name = args.entry or args.chapter
    state_path = STATE_DIR / f"{lang}.{name}.json"

    quiz = load_items(lang, "quiz")
    taken = {x["id"] for kind in ("quiz", "gen", "rules") for x in load_items(lang, kind)}
    state = {"lang": lang, "target": name, "level": level, "batches_done": 0,
             "issued": [], "appended": [], "rejected": [], "pending": None}
    if state_path.exists() and not args.dry_run:
        state = json.loads(state_path.read_text(encoding="utf-8"))
        print(f"resuming {state_path.name}: {state['batches_done']} batch(es) done, "
              f"{len(state['appended'])} item(s) appended")

    def save():
        if args.dry_run:
            return
        STATE_DIR.mkdir(exist_ok=True)
        write_atomic(state_path, json.dumps(state, ensure_ascii=False, indent=1) + "\n")

    slug = chapter["id"].split(".", 1)[1]
    prefix = f"{code}.q.top.{slug}."

    def next_id():
        used = taken | set(state["issued"])
        n = 1 + max([int(i[len(prefix):]) for i in used
                     if i.startswith(prefix) and i[len(prefix):].isdigit()] or [0])
        iid = f"{prefix}{n}"
        state["issued"].append(iid)
        return iid

    entries = {e["id"] for e in target["entries"]}
    bank = [x for x in quiz + load_items(lang, "gen") if x.get("entry") in entries]
    rng = random.Random(args.seed + state["batches_done"])

    def used_now():
        return [text(x) for x in bank] + [text(x) for x in state["appended"]]

    def write_payload():
        allowed = set(formats(chapter))
        pool = [x for x in bank if x.get("format") in allowed]
        examples = rng.sample(pool, min(8, len(pool)))
        return body(SYSTEM, request(target, level, examples, used_now(), args.count), SCHEMA, 16_000)

    if args.dry_run:
        payload = write_payload()
        print(f"POST https://api.anthropic.com/v1/messages  (model {MODEL}; "
              f"ids from {prefix}N; would append to quiz-{lang}.json)\n")
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        print("\nThen a check call per batch (TopUp.checkSystem) on the kept drafts.")
        return

    key = load_key()
    try:
        while state["batches_done"] < args.batches:
            p = state["pending"]
            if p is None:
                print(f"batch {state['batches_done'] + 1}/{args.batches}: writing…", flush=True)
                drafts = call(key, write_payload()).get("items", [])
                p = state["pending"] = {"stage": "written", "drafts": drafts}
                save()
            if p["stage"] == "written":
                kept, dropped = keep(p["drafts"], target, used_now(), next_id)
                state["rejected"] += [{"why": w, "draft": d} for w, d in dropped]
                p.update(stage="kept", kept=kept)
                save()
                print(f"  {len(p['drafts'])} written, {len(kept)} kept", flush=True)
            if p["stage"] == "kept":
                fail = set(call(key, body(CHECK_SYSTEM, check_request(p["kept"]), CHECK_SCHEMA, 4_000))
                           .get("fail", [])) if p["kept"] else set()
                state["rejected"] += [{"why": "check", "item": x} for i, x in enumerate(p["kept"]) if i in fail]
                p.update(stage="checked", kept=[x for i, x in enumerate(p["kept"]) if i not in fail])
                save()
                print(f"  {len(fail)} failed the check", flush=True)
            if p["stage"] == "checked":
                # The file may hold some of these already if a run died mid-append.
                quiz = load_items(lang, "quiz")
                have = {x["id"] for x in quiz}
                new = [x for x in p["kept"] if x["id"] not in have]
                state["appended"] += [x for x in p["kept"] if x["id"] in have]
                book_entries = audit_content.book_entries(lang)
                ids = {x["id"] for kind in ("quiz", "gen", "rules") for x in load_items(lang, kind)}
                good = []
                for x in new:
                    problems = audit_content.audit_items([x], lang, book_entries, set(ids))
                    errs = []
                    check_book.check_item(x, {e: {} for e in book_entries}, set(ids), errs, [])
                    if problems or errs:
                        state["rejected"].append({"why": "audit", "item": x,
                                                  "problems": [list(p_) for p_ in problems] + errs})
                    else:
                        good.append(x)
                        ids.add(x["id"])
                if good:
                    write_atomic(CUR / f"quiz-{lang}.json", dump_items(quiz + good))
                state["appended"] += good
                state["batches_done"] += 1
                state["pending"] = None
                save()
                print(f"  appended {len(good)} to quiz-{lang}.json", flush=True)
    except KeyboardInterrupt:
        save()
        print(f"\ninterrupted — progress in {state_path}; rerun the same command to resume")
        sys.exit(130)
    except Exception as e:
        save()
        sys.exit(f"stopped: {e} — progress in {state_path}; rerun to resume")
    print(f"done: {len(state['appended'])} item(s) appended in all, "
          f"{len(state['rejected'])} rejected (see {state_path})")


if __name__ == "__main__":
    main()
