#!/usr/bin/env python3
"""Write Curriculum/concepts.json: one meaning across languages, for the
ALL LANGUAGES deck. A row joins words from vocab-<lang>.json whose English
glosses match once normalised (first sense, no brackets), preferring the
plain sense and a shared part of speech; each word keeps its
own schedule in the quiz log, so the rows hold words, not new data.
A row holds every language that matched, two at least; the app uses the rows
that cover all the languages the learner has on.

    python3 tools/build_concepts.py

A language whose word's part of speech can't be the others' is left out of
the row (사이 is a noun for "between"). Rows already shipped keep their words:
a word swapped under a learner moves the card's schedule to another word.

Rows are sorted easiest first: by the highest of the words' bands, each as a
share of its list's top band.
"""
import json, pathlib, re, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from audit_content import pos_clash

ROOT = pathlib.Path(__file__).resolve().parent.parent
CUR = ROOT / "gentence-senerator/gentence-senerator/Curriculum"
LANGS = {"de": "german", "fr": "french", "es": "spanish", "zh": "mandarin", "ko": "korean"}
TOP = {"de": 4, "fr": 4, "es": 4, "zh": 6, "ko": 4}


def norm(gloss):
    g = re.sub(r"\(.*?\)", "", (gloss or "").lower())
    return g.split(";")[0].split(",")[0].strip()


def sense(gloss):
    """The bracketed qualifier on the first sense: "cold (illness)" → "illness"."""
    m = re.search(r"\((.*?)\)", (gloss or "").split(";")[0])
    return m.group(1).strip().lower() if m else ""


def main():
    index, by_word = {}, {}
    for code, lang in LANGS.items():
        index[code], by_word[code] = {}, {}
        path = CUR / f"vocab-{lang}.json"
        if not path.exists():
            continue
        for w in json.loads(path.read_text()):
            if w.get("skip") or not w.get("en"):
                continue
            by_word[code].setdefault(w["w"], w)
            key = norm(w["en"])
            if key:
                index[code].setdefault(key, []).append(w)
    path = CUR / "concepts.json"
    shipped = {r["en"]: r for r in json.loads(path.read_text())} if path.exists() else {}
    keys = set().union(*(set(v) for v in index.values()))
    rows = []
    for key in keys:
        # A shipped row's words stand even where their glosses have since
        # drifted from the row's key.
        pinned = {c for c in LANGS if shipped.get(key, {}).get(c) in by_word[c]}
        here = [c for c in LANGS if key in index[c] or c in pinned]
        if len(here) < 2:
            continue
        # The plain sense beats a qualified one ("cold" over "cold (illness)"),
        # then the part of speech most of the plain candidates share (kalt
        # over Kälte, beside froid and 冷), then the commoner word.
        plain = [w for c in here for w in index[c].get(key, []) if not sense(w["en"])]
        poses = [w.get("pos") for w in plain]
        vote = max(set(poses), key=poses.count) if poses else None
        words = {c: by_word[c][shipped[key][c]] if c in pinned else
                 min(index[c][key], key=lambda w: (bool(sense(w["en"])), w.get("pos") != vote, w["band"]))
                 for c in here}
        # Every side qualified, and not the same way: different meanings.
        if not pinned and len({sense(words[c]["en"]) for c in here}) > 1:
            continue
        # Drop the language clashing with the most others, never a pinned one.
        while len(here) > 1:
            clashes = pos_clash({c: words[c].get("pos") for c in here})
            blame = {c: sum(f"{c}=" in x for x in clashes) for c in here if c not in pinned}
            if not clashes or not blame or max(blame.values()) == 0:
                break
            here.remove(max(blame, key=lambda c: (blame[c], c)))
        if len(here) < 2:
            continue
        hard = max(words[c]["band"] / TOP[c] for c in here)
        rows.append((hard, key, {"en": key, **{c: words[c]["w"] for c in here}}))
    rows.sort(key=lambda r: (r[0], r[1]))
    out = [r[2] for r in rows]
    lines = ",\n".join(json.dumps(r, ensure_ascii=False) for r in out)
    (CUR / "concepts.json").write_text("[\n" + lines + "\n]\n")
    print(f"concepts.json: {len(out)} rows")


if __name__ == "__main__":
    main()
