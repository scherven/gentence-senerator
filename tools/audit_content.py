#!/usr/bin/env python3
"""Audit the bundled content files for data errors the format checks miss.

Deterministic, no network. Covers Curriculum/quiz-, rules-, gen-, vocab- and
words-<lang>.json and concepts.json. Read alongside tools/check_book.py, which
owns the format rules (steps, option counts, tiles, accept) and chapter
coverage; the item checks here repeat only the ones the app would drop an item
for, so the two never disagree, and add what a format check can't see:

    answer        a step's answer index out of range
    dup-option    the same option twice in a step
    answer-twice  a distractor that is the answer once width and spacing are
                  folded (case is kept: German tests capitals)
    gaps          the number of ＿ in the prompt doesn't fit the format
    entry         the entry id isn't in book-<lang>.json
    empty         an empty or whitespace-only string
    mojibake      broken escapes or double-encoded text (f"ur, u00e9, Ã©)
    pinyin        pinyin without tone marks where the others have them
    dup-id        an id (item id, vocab word, concept, words key) seen twice
    pos           a concept row whose words differ in part of speech
    field         a missing or mistyped required field

    python3 tools/audit_content.py [mandarin german french spanish korean] [-v]

Exits 1 if any file has an error. Other tools import `audit_items` to check
items before writing them.
"""
import collections, json, pathlib, re, sys, unicodedata

ROOT = pathlib.Path(__file__).resolve().parent.parent
CUR = ROOT / "gentence-senerator/gentence-senerator/Curriculum"
LANGS = ("mandarin", "german", "french", "spanish", "korean")
CODE = {"mandarin": "zh", "german": "de", "french": "fr", "spanish": "es", "korean": "ko"}
GAP = "＿"
FORMATS = {"pick-one", "flip", "build", "two-step", "spot-it", "tone-tap",
           "sort", "transform", "card"}
STRING_FIELDS = ("prompt", "gloss", "task", "speak", "why")
LIST_FIELDS = ("tiles", "decoys", "accept")
SHOW = 5

# --- text checks -----------------------------------------------------------

TONE = re.compile("[āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ]")
# Syllables that are neutral tone by nature, so carry no mark.
NEUTRAL = {"a", "ba", "de", "le", "ma", "me", "men", "ne", "zhe", "wa", "la",
           "ya", "na", "zi", "ge", "guo", "lou", "li", "r", "er"}
MOJIBAKE = [
    (re.compile(r"[ÃÂ][\u0080-\u00bf]"), "double-encoded UTF-8"),
    (re.compile(r"â€|â€™|â€œ"), "double-encoded punctuation"),
    (re.compile(r"\\u[0-9a-fA-F]{4}|(?<![0-9A-Za-z])u00[0-9a-fA-F]{2}"), "unicode escape left in"),
    (re.compile(r"[A-Za-z]\"[aouAOUs](?![A-Za-z]*\")"), "TeX umlaut (f\"ur)"),
    (re.compile(r"\\[\"'`^nt]"), "backslash escape left in"),
    (re.compile("\ufffd"), "replacement character"),
    (re.compile(r"[\x00-\x08\x0b-\x1f\x7f]"), "control character"),
]


def mojibake(s):
    for rx, what in MOJIBAKE:
        if rx.search(s):
            return what
    return None


def fold(s):
    """How a learner would see two options as the same: full-width and
    spacing folded. Not case: German tests capitals (Hinsehen / hinsehen)."""
    return " ".join(unicodedata.normalize("NFKC", s).split())


def strip_tones(s):
    return "".join(c for c in unicodedata.normalize("NFD", s)
                   if unicodedata.category(c) != "Mn").replace("ü", "v")


def toneless_pinyin(py):
    """True when a pinyin string has no tone mark and isn't a neutral particle."""
    py = py.strip()
    if not py or TONE.search(py):
        return False
    return py.lower() not in NEUTRAL


def strings(obj, path=""):
    """Every string in a JSON value, with where it sits."""
    if isinstance(obj, str):
        yield path, obj
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from strings(v, f"{path}[{i}]")
    elif isinstance(obj, dict):
        for k, v in obj.items():
            yield from strings(v, f"{path}.{k}" if path else k)


def text_checks(key, obj, add, skip=()):
    for path, s in strings(obj):
        if path in skip:
            continue
        if not s.strip():
            add("empty", key, path)
        else:
            m = mojibake(s)
            if m:
                add("mojibake", key, f"{path}: {m}")


# --- loading ---------------------------------------------------------------

class Dupes(dict):
    pass


def load(path):
    """JSON with duplicate object keys recorded rather than silently merged."""
    dupes = []

    def hook(pairs):
        d = Dupes()
        for k, v in pairs:
            if k in d:
                dupes.append(k)
            d[k] = v
        return d

    data = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=hook)
    return data, dupes


def book_entries(lang):
    path = CUR / f"book-{lang}.json"
    if not path.exists():
        return set()
    book = json.loads(path.read_text(encoding="utf-8"))
    return {e.get("id") for ch in book.get("chapters", []) for e in ch.get("entries", [])}


# --- items -----------------------------------------------------------------

def gap_problem(fmt, prompt, steps):
    n = (prompt or "").count(GAP)
    if fmt in ("pick-one", "flip"):
        return None if n == 1 else f"{fmt} needs 1 gap, has {n}"
    if fmt == "two-step":
        return None if 1 <= n <= max(len(steps), 1) else f"two-step needs 1-{len(steps)} gaps, has {n}"
    return None if n == 0 else f"{fmt} has {n} gap(s), needs none"


def audit_items(items, lang, entries, seen=None, add=None):
    """Checks quiz items (quiz-, gen-, rules- or new top-ups). `seen` is the
    set of ids already taken and is updated. Returns [(check, id, detail)]."""
    out = []
    add = add or (lambda c, i, d="": out.append((c, i, d)))
    seen = set() if seen is None else seen
    for n, it in enumerate(items):
        if not isinstance(it, dict):
            add("field", f"#{n}", "not an object")
            continue
        iid = it.get("id")
        if not isinstance(iid, str) or not iid.strip():
            add("field", f"#{n}", "id missing")
            iid = f"#{n}"
        elif iid in seen:
            add("dup-id", iid)
        else:
            seen.add(iid)
        for k in ("entry", "format"):
            if not isinstance(it.get(k), str):
                add("field", iid, f"{k} missing")
        for k in STRING_FIELDS:
            if k in it and not isinstance(it[k], str):
                add("field", iid, f"{k} not a string")
        for k in LIST_FIELDS:
            if k in it and not (isinstance(it[k], list) and all(isinstance(x, str) for x in it[k])):
                add("field", iid, f"{k} not a list of strings")
        fmt = it.get("format")
        if fmt not in FORMATS:
            add("field", iid, f"bad format {fmt!r}")
        if it.get("entry") not in entries:
            add("entry", iid, str(it.get("entry")))
        text_checks(iid, {k: v for k, v in it.items() if k not in ("id", "entry", "format")}, add)

        steps = it.get("steps", [])
        if not isinstance(steps, list):
            add("field", iid, "steps not a list")
            steps = []
        for i, s in enumerate(steps):
            opts = s.get("options") if isinstance(s, dict) else None
            if not isinstance(opts, list) or not all(isinstance(o, str) for o in opts):
                add("field", iid, f"step {i} options")
                continue
            a = s.get("answer")
            if not isinstance(a, int) or isinstance(a, bool) or not 0 <= a < len(opts):
                add("answer", iid, f"step {i}: {a!r} of {len(opts)}")
                a = None
            if len(set(opts)) != len(opts):
                d = [o for o, c in collections.Counter(opts).items() if c > 1]
                add("dup-option", iid, f"step {i}: {d}")
            elif a is not None:
                same = [o for j, o in enumerate(opts) if j != a and fold(o) == fold(opts[a])]
                if same:
                    add("answer-twice", iid, f"step {i}: {opts[a]!r} ~ {same}")
        # A build decoy may equal a tile (他 … 他 tempts a repeated subject):
        # build is graded on the joined text, so it costs nothing.
        if fmt in FORMATS:
            g = gap_problem(fmt, it.get("prompt"), steps)
            if g:
                add("gaps", iid, g)
        if lang == "mandarin" and fmt == "tone-tap":
            for i, s in enumerate(steps):
                opts = s.get("options", []) if isinstance(s, dict) else []
                bare = [o for o in opts if isinstance(o, str) and not TONE.search(o)]
                if len(bare) > 1 or (len(opts) == 4 and bare):
                    add("pinyin", iid, f"step {i}: no tone mark on {bare}")
                bases = {strip_tones(o).lower() for o in opts if isinstance(o, str)}
                if len(bases) > 1:
                    add("pinyin", iid, f"step {i}: options are different syllables {sorted(bases)}")
            why = it.get("why")
            if isinstance(why, str) and re.fullmatch(r"[a-zA-Zü' ]+", why) and toneless_pinyin(why):
                add("pinyin", iid, f"why {why!r} has no tone mark")
    return out


# --- other files -----------------------------------------------------------

def audit_vocab(words, lang, add):
    seen = set()
    for n, w in enumerate(words):
        if not isinstance(w, dict) or not isinstance(w.get("w"), str):
            add("field", f"#{n}", "w missing")
            continue
        key = w["w"]
        if key in seen:
            add("dup-id", key)
        seen.add(key)
        if not isinstance(w.get("band"), int):
            add("field", key, "band not an int")
        if w.get("skip") is not True and not isinstance(w.get("en"), str):
            add("field", key, "en missing")
        text_checks(key, w, add)
        if lang == "mandarin":
            py = w.get("py")
            if not isinstance(py, str) or not py.strip():
                add("pinyin", key, "py missing")
            elif re.search(r"[1-5]", py):
                add("pinyin", key, f"tone numbers in {py!r}")
            elif toneless_pinyin(py):
                add("pinyin", key, f"{py!r} has no tone mark")
    return seen


# Parts of speech that are the same word class in another tagging, so a row
# may mix them. Any language: adjectives double as adverbs in German, and
# determiners as pronouns or numerals (un). Mandarin also tags time words and place words as
# nouns (明天, 后边), question words as pronouns (怎么, 哪儿), and 谢谢 as a verb.
COMPAT = {frozenset(p) for p in [("adj", "adv"), ("adv", "conj"), ("det", "pron"), ("det", "num")]}
COMPAT_ZH = COMPAT | {frozenset(p) for p in [
    ("noun", "adv"), ("noun", "prep"), ("pron", "adv"), ("pron", "det"),
    ("pron", "adj"), ("adv", "det"), ("verb", "interj"), ("num", "noun")]}


def pos_clash(poses):
    """Pairs of a row's words whose parts of speech can't be the same word."""
    out = []
    codes = sorted(poses)
    for i, a in enumerate(codes):
        for b in codes[i + 1:]:
            pa, pb = poses[a], poses[b]
            ok = COMPAT_ZH if "zh" in (a, b) else COMPAT
            if pa != pb and frozenset((pa, pb)) not in ok:
                out.append(f"{a}={pa}/{b}={pb}")
    return out


def audit_concepts(rows, vocab_pos, add):
    seen = set()
    for n, r in enumerate(rows):
        if not isinstance(r, dict):
            add("field", f"#{n}", "not an object")
            continue
        key = r.get("en") if isinstance(r.get("en"), str) else f"#{n}"
        if not isinstance(r.get("en"), str):
            add("field", key, "en missing")
        codes = [c for c in CODE.values() if c in r]
        if len(codes) < 2:
            add("field", key, f"only {codes}: a row needs two languages")
        if key in seen:
            add("dup-id", key)
        seen.add(key)
        text_checks(key, r, add)
        poses = {}
        for code in codes:
            word = r.get(code)
            if not isinstance(word, str):
                add("field", key, f"{code} not a string")
                continue
            if word not in vocab_pos[code]:
                add("field", key, f"{code} {word!r} not in vocab")
            else:
                poses[code] = vocab_pos[code][word]
        # Only when every word has a definite part of speech.
        if len(poses) == len(codes) and not {"other", "phrase"} & set(poses.values()):
            clash = pos_clash(poses)
            if clash:
                add("pos", key, " ".join(clash))


def audit_words(data, add):
    if not isinstance(data, dict) or not isinstance(data.get("words"), dict):
        add("field", "words", "no words object")
        return
    for w, band in data["words"].items():
        if not w.strip():
            add("empty", repr(w), "key")
        m = mojibake(w)
        if m:
            add("mojibake", w, m)
        if not isinstance(band, int) or isinstance(band, bool):
            add("field", w, f"band {band!r}")
    text_checks("meta", data.get("meta", {}), add)


# --- driver ----------------------------------------------------------------

class Report:
    def __init__(self, name):
        self.name = name
        self.hits = collections.defaultdict(list)

    def add(self, check, key, detail=""):
        self.hits[check].append((key, detail))

    @property
    def errors(self):
        return sum(len(v) for v in self.hits.values())

    def print(self, verbose=False):
        if not self.hits:
            print(f"{self.name}: ok")
            return
        print(f"{self.name}: {self.errors} error(s)")
        for check in sorted(self.hits):
            hits = self.hits[check]
            shown = hits if verbose else hits[:SHOW]
            print(f"  {check:13} {len(hits):5}  " + ", ".join(
                f"{k}" + (f" ({d})" if d else "") for k, d in shown)
                + (" …" if len(hits) > len(shown) else ""))


def run(langs, verbose=False):
    reports = []
    vocab_pos = {}
    for lang in LANGS:
        path = CUR / f"vocab-{lang}.json"
        words = json.loads(path.read_text(encoding="utf-8")) if path.exists() else []
        vocab_pos[CODE[lang]] = {w.get("w"): w.get("pos") for w in words if isinstance(w, dict)}

    for lang in langs:
        entries = book_entries(lang)
        seen = set()   # quiz, gen and rules share one id space, as in check_book
        for kind in ("quiz", "gen", "rules"):
            path = CUR / f"{kind}-{lang}.json"
            if not path.exists():
                continue
            rep = Report(path.name)
            data, dupes = load(path)
            for k in dupes:
                rep.add("dup-id", k, "duplicate key")
            if not isinstance(data, list):
                rep.add("field", path.name, "not an array")
            else:
                audit_items(data, lang, entries, seen, rep.add)
            reports.append(rep)
        for kind, fn in (("vocab", lambda d, r: audit_vocab(d, lang, r.add)),
                         ("words", lambda d, r: audit_words(d, r.add))):
            path = CUR / f"{kind}-{lang}.json"
            if not path.exists():
                continue
            rep = Report(path.name)
            data, dupes = load(path)
            for k in dupes:
                rep.add("dup-id", k, "duplicate key")
            fn(data, rep)
            reports.append(rep)

    path = CUR / "concepts.json"
    if path.exists():
        rep = Report(path.name)
        data, dupes = load(path)
        for k in dupes:
            rep.add("dup-id", k, "duplicate key")
        audit_concepts(data, vocab_pos, rep.add)
        reports.append(rep)
    for r in reports:
        r.print(verbose)
    total = sum(r.errors for r in reports)
    print(f"\n{total} error(s) in {sum(1 for r in reports if r.errors)} of {len(reports)} files")
    return total


def main():
    args = sys.argv[1:]
    verbose = "-v" in args
    langs = [a for a in args if a in LANGS] or list(LANGS)
    sys.exit(1 if run(langs, verbose) else 0)


if __name__ == "__main__":
    main()
