#!/usr/bin/env python3
"""Write Curriculum/concepts.json: one meaning in all three languages, for the
ALL LANGUAGES deck. A row joins words from vocab-<lang>.json whose English
glosses match once normalised (first sense, no brackets), preferring the
plain sense and a shared part of speech; each word keeps its
own schedule in the quiz log, so the rows hold words, not new data.

    python3 tools/build_concepts.py

Rows are sorted easiest first: by the highest of the three words' bands, each
as a share of its list's top band.
"""
import json, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parent.parent
CUR = ROOT / "gentence-senerator/gentence-senerator/Curriculum"
LANGS = {"de": "german", "fr": "french", "zh": "mandarin"}
TOP = {"de": 4, "fr": 4, "zh": 6}


def norm(gloss):
    g = re.sub(r"\(.*?\)", "", (gloss or "").lower())
    return g.split(";")[0].split(",")[0].strip()


def sense(gloss):
    """The bracketed qualifier on the first sense: "cold (illness)" → "illness"."""
    m = re.search(r"\((.*?)\)", (gloss or "").split(";")[0])
    return m.group(1).strip().lower() if m else ""


def main():
    index = {}
    for code, lang in LANGS.items():
        index[code] = {}
        for w in json.loads((CUR / f"vocab-{lang}.json").read_text()):
            if w.get("skip") or not w.get("en"):
                continue
            key = norm(w["en"])
            if key:
                index[code].setdefault(key, []).append(w)
    shared = set.intersection(*(set(v) for v in index.values()))
    rows = []
    for key in shared:
        # The plain sense beats a qualified one ("cold" over "cold (illness)"),
        # then the part of speech most of the plain candidates share (kalt
        # over Kälte, beside froid and 冷), then the commoner word.
        plain = [w for c in LANGS for w in index[c][key] if not sense(w["en"])]
        poses = [w.get("pos") for w in plain]
        vote = max(set(poses), key=poses.count) if poses else None
        words = {c: min(index[c][key], key=lambda w: (bool(sense(w["en"])), w.get("pos") != vote, w["band"]))
                 for c in LANGS}
        # Every side qualified, and not the same way: different meanings.
        if len({sense(words[c]["en"]) for c in LANGS}) > 1:
            continue
        hard = max(words[c]["band"] / TOP[c] for c in LANGS)
        rows.append((hard, key, {"en": key, **{c: words[c]["w"] for c in LANGS}}))
    rows.sort(key=lambda r: (r[0], r[1]))
    out = [r[2] for r in rows]
    lines = ",\n".join(json.dumps(r, ensure_ascii=False) for r in out)
    (CUR / "concepts.json").write_text("[\n" + lines + "\n]\n")
    print(f"concepts.json: {len(out)} rows")


if __name__ == "__main__":
    main()
