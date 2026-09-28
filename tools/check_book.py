#!/usr/bin/env python3
"""Validate Curriculum/book-<lang>.json and quiz-<lang>.json against the
contract in Core/Book.swift and Core/Quiz.swift. Exits nonzero on any error.

    python3 tools/check_book.py [--upto N] [mandarin german french]

--upto N limits the coverage check (every curriculum point has an entry, and
2+ items across its entries) to points at level N or below.
"""
import json, sys, pathlib, collections

ROOT = pathlib.Path(__file__).resolve().parent.parent
CUR = ROOT / "gentence-senerator/gentence-senerator/Curriculum"
PREFIX = {"mandarin": "zh", "german": "de", "french": "fr"}
LEVELS = {"mandarin": 9, "german": 6, "french": 6}
LAYOUTS = {"list", "cards", "formulas", "pairs", "split"}
GAP = "＿"
# (steps, options, tiles, accept) — mirrors QuizFormat.rules
RULES = {
    "pick-one":  ((1, 1), (3, 4), False, False),
    "flip":      ((1, 1), (2, 2), False, False),
    "build":     ((0, 0), None, True, False),
    "two-step":  ((2, 2), (2, 5), False, False),
    "spot-it":   ((2, 2), (2, 12), False, False),
    "tone-tap":  ((1, 4), (4, 5), False, False),
    "sort":      ((4, 12), (2, 4), False, False),
    "transform": ((0, 0), None, False, True),
}


def check(lang, upto=None):
    errs, warn = [], []
    p = PREFIX[lang]
    book_path, quiz_path = CUR / f"book-{lang}.json", CUR / f"quiz-{lang}.json"
    if not book_path.exists():
        return [f"{lang}: missing {book_path.name}"], warn
    book = json.loads(book_path.read_text())
    items = json.loads(quiz_path.read_text()) if quiz_path.exists() else []
    point_level = {g["id"]: g["level"] for g in json.loads((CUR / f"grammar-{lang}.json").read_text())}
    points = set(point_level)

    if book.get("language") != lang:
        errs.append(f"book language {book.get('language')!r} != {lang!r}")
    entries, chapter_of, chapter_ids = {}, {}, set()
    for ch in book.get("chapters", []):
        cid = ch.get("id", "")
        if not cid.startswith(p + "."):
            errs.append(f"chapter id {cid!r} must start with {p}.")
        if cid in chapter_ids:
            errs.append(f"duplicate chapter {cid}")
        chapter_ids.add(cid)
        for k in ("name", "sub", "layout", "entries", "formats"):
            if k not in ch:
                errs.append(f"{cid}: missing {k}")
        if ch.get("layout") not in LAYOUTS:
            errs.append(f"{cid}: bad layout {ch.get('layout')!r}")
        for f in ch.get("formats", []):
            if f not in RULES:
                errs.append(f"{cid}: bad format {f!r}")
        for e in ch.get("entries", []):
            eid = e.get("id", "")
            if not eid.startswith(p + "."):
                errs.append(f"entry id {eid!r} must start with {p}.")
            if eid in entries:
                errs.append(f"duplicate entry {eid}")
            if not e.get("head"):
                errs.append(f"{eid}: missing head")
            lv = e.get("level")
            if not isinstance(lv, int) or not 1 <= lv <= LEVELS[lang]:
                errs.append(f"{eid}: level must be 1-{LEVELS[lang]}, is {lv!r}")
            if e.get("point") and e["point"] not in points:
                errs.append(f"{eid}: unknown point {e['point']!r}")
            if ch.get("layout") in ("pairs", "split"):
                for k in ("group", "tag"):
                    if not e.get(k):
                        errs.append(f"{eid}: {ch['layout']} layout needs {k}")
            entries[eid] = e
            chapter_of[eid] = cid
    for d in book.get("drills", []):
        for c in d.get("chapters", []):
            if c not in chapter_ids:
                errs.append(f"drill {d.get('id')}: unknown chapter {c}")
        for f in d.get("formats", []):
            if f not in RULES:
                errs.append(f"drill {d.get('id')}: bad format {f}")

    seen = set()
    per_chapter = collections.Counter()
    per_chapter_format = collections.defaultdict(set)
    for it in items:
        iid = it.get("id", "")
        if iid in seen:
            errs.append(f"duplicate item {iid}")
        seen.add(iid)
        eid = it.get("entry")
        if eid not in entries:
            errs.append(f"{iid}: unknown entry {eid!r}")
            continue
        f = it.get("format")
        if f not in RULES:
            errs.append(f"{iid}: bad format {f!r}")
            continue
        (smin, smax), opts, tiles, accept = RULES[f]
        steps = it.get("steps", [])
        if not smin <= len(steps) <= smax:
            errs.append(f"{iid}: {f} needs {smin}-{smax} steps, has {len(steps)}")
        for i, s in enumerate(steps):
            o = s.get("options", [])
            if opts and not opts[0] <= len(o) <= opts[1]:
                errs.append(f"{iid}: step {i} needs {opts[0]}-{opts[1]} options, has {len(o)}")
            if not isinstance(s.get("answer"), int) or not 0 <= s["answer"] < len(o):
                errs.append(f"{iid}: step {i} answer out of range")
            if len(set(o)) != len(o):
                errs.append(f"{iid}: step {i} duplicate options")
        if f == "sort" and len({tuple(s.get("options", [])) for s in steps}) > 1:
            errs.append(f"{iid}: sort steps must share buckets")
        if tiles and len(it.get("tiles", [])) < 2:
            errs.append(f"{iid}: build needs 2+ tiles")
        if accept and not it.get("accept"):
            errs.append(f"{iid}: transform needs accept")
        if f == "transform" and not it.get("task"):
            errs.append(f"{iid}: transform needs task")
        if f in ("pick-one", "flip", "two-step") and GAP not in (it.get("prompt") or ""):
            errs.append(f"{iid}: {f} prompt needs a {GAP} gap")
        if f == "tone-tap" and not it.get("speak"):
            errs.append(f"{iid}: tone-tap needs speak")
        why = it.get("why")
        if why and len(why.split()) > 4:
            warn.append(f"{iid}: why longer than 3 words: {why!r}")
        per_chapter[chapter_of[eid]] += 1
        per_chapter_format[chapter_of[eid]].add(f)

    point_entries = collections.defaultdict(list)
    for eid, e in entries.items():
        if e.get("point"):
            point_entries[e["point"]].append(eid)
    per_entry = collections.Counter(it.get("entry") for it in items)
    for pid, lv in sorted(point_level.items(), key=lambda kv: kv[1]):
        if upto is not None and lv > upto:
            continue
        if not point_entries[pid]:
            errs.append(f"point {pid} (level {lv}) has no entry")
        elif sum(per_entry[e] for e in point_entries[pid]) < 2:
            errs.append(f"point {pid} (level {lv}) has fewer than 2 items")

    for ch in book.get("chapters", []):
        cid = ch["id"]
        if per_chapter[cid] < 30:
            errs.append(f"{cid}: {per_chapter[cid]} items, need 30+")
        missing = set(ch.get("formats", [])) - per_chapter_format[cid]
        if missing:
            errs.append(f"{cid}: formats with no items: {sorted(missing)}")
    return errs, warn


def main():
    args = sys.argv[1:]
    upto = None
    if "--upto" in args:
        i = args.index("--upto")
        upto = int(args[i + 1])
        del args[i:i + 2]
    langs = args or list(PREFIX)
    bad = False
    for lang in langs:
        errs, warn = check(lang, upto)
        for w in warn:
            print(f"warn {lang}: {w}")
        for e in errs:
            print(f"ERROR {lang}: {e}")
        bad |= bool(errs)
        if not errs:
            print(f"{lang}: ok")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
