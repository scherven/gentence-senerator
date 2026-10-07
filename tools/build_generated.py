#!/usr/bin/env python3
"""Write Curriculum/gen-<lang>.json: test items made from the vocab lists, no
model. Gender (German, French) and tones (Mandarin), each linked to the book
entry whose rule it shows. Only what links cleanly is kept: an ending that
belongs to the word (not just its spelling), an article that agrees with the
rule, a tone the audio says as written.

    python3 tools/build_generated.py && python3 tools/check_book.py

Deterministic: the same data gives the same file.
"""
import json, pathlib, re

ROOT = pathlib.Path(__file__).resolve().parent.parent
CUR = ROOT / "gentence-senerator/gentence-senerator/Curriculum"
GAP = "＿"


def load(kind, lang):
    return json.loads((CUR / f"{kind}-{lang}.json").read_text())


def used_words(lang, prefix):
    """Words the shipped tests already ask, so generated ones don't repeat them."""
    out = set()
    for i in load("quiz", lang):
        if i["entry"].startswith(prefix):
            out |= {w.strip(".,!?") for w in (i.get("prompt") or "").replace(GAP, " ").split()}
    return out


# ---------------------------------------------------------------- German gender
DE_TIME = {"Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag", "Sonnabend",
           "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober",
           "November", "Dezember", "Frühling", "Sommer", "Herbst", "Winter", "Frühjahr"}
# Endings long enough to be the suffix and not the last letters of a stem.
# -e, -ig, -ist, -ik, -ur, -ie, -ei, -um matched by spelling alone taught false
# rules in the sample (Gehsteig, Frist), so they are left to the sentences.
DE_SUFFIX = [("ismus", ("ismus",)), ("schaft", ("schaft",)), ("heit-keit", ("heit", "keit")),
             ("chen-lein", ("chen", "lein")), ("ling", ("ling",)), ("ung", ("ung",)),
             ("ion", ("ion",)), ("taet", ("tät",))]


def de_gender():
    entries = {e["id"]: e for c in load("book", "german")["chapters"] if c["id"] == "de.gender"
               for e in c["entries"]}
    verbs = {v["w"] for v in load("vocab", "german") if v.get("pos") == "verb"}
    used = used_words("german", "de.gender.")
    items = []
    for n in load("vocab", "german"):
        w, art = n["w"], n.get("art")
        if n.get("pos") != "noun" or art not in ("der", "die", "das") or w in used or not w[0].isupper():
            continue
        rule = None
        if w in DE_TIME:
            rule = "de.gender.time"
        elif w.lower() in verbs:
            rule = "de.gender.infinitive"
        else:
            for key, sufs in DE_SUFFIX:
                if any(w.endswith(s) and len(w) > len(s) + 2 for s in sufs):
                    rule = f"de.gender.{key}"
                    break
        if not rule or entries[rule]["tag"] != art:
            continue
        items.append({"id": f"gen.{rule}.{w}", "entry": rule, "format": "pick-one",
                      "prompt": f"{GAP} {w}", "gloss": n.get("en"), "why": entries[rule]["head"].split(" · ")[0],
                      "steps": [{"options": ["der", "die", "das"], "answer": ["der", "die", "das"].index(art)}]})
    return items


# ---------------------------------------------------------------- French gender
# (ending, the article the rule gives, entry). Exceptions with their own entry
# are linked there.
FR_SUFFIX = [("isme", "le", "isme"), ("ment", "le", "ment"), ("tion", "la", "tion"), ("sion", "la", "tion"),
             ("ette", "la", "ette"), ("ence", "la", "ence"), ("ance", "la", "ence"), ("age", "le", "age"),
             ("eau", "le", "eau"), ("ème", "le", "eme"), ("oir", "le", "oir"), ("ier", "le", "ier"),
             ("ure", "la", "ure"), ("ée", "la", "ee"), ("té", "la", "te")]
FR_EXC = {("age", "la"): "x-age", ("eau", "la"): "x-eau", ("ee", "le"): "x-ee", ("te", "le"): "x-te",
          ("ence", "le"): "x-ence", ("eme", "la"): "x-eme"}
VOWEL = "aeiouyàâäéèêëîïôöùûüœæh"


def fr_gender():
    used = used_words("french", "fr.gender.")
    items = []
    for n in load("vocab", "french"):
        w, art = n["w"], n.get("art")
        # l' and h- hide the article; a phrase has no single ending.
        if n.get("pos") != "noun" or art not in ("le", "la") or w in used or w[0].lower() in VOWEL \
                or " " in w or "-" in w:
            continue
        for suf, rule_art, key in FR_SUFFIX:
            if w.endswith(suf) and len(w) > len(suf) + 1:
                entry = key if art == rule_art else FR_EXC.get((key, art))
                if entry:
                    items.append({"id": f"gen.fr.gender.{entry}.{w}", "entry": f"fr.gender.{entry}",
                                  "format": "flip", "prompt": f"{GAP} {w}", "gloss": n.get("en"),
                                  "why": f"{art} {w}",
                                  "steps": [{"options": ["le", "la"], "answer": ["le", "la"].index(art)}]})
                break
    return items


# ---------------------------------------------------------------- Mandarin tones
INITIALS = ["zh", "ch", "sh", "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "r", "z", "c", "s", "y", "w", ""]
FINALS = ["a", "o", "e", "ai", "ei", "ao", "ou", "an", "en", "ang", "eng", "ong", "er", "i", "ia", "ie", "iao", "iu", "ian",
          "in", "iang", "ing", "iong", "u", "ua", "uo", "uai", "ui", "uan", "un", "uang", "ueng", "ü", "üe", "üan", "ün", "ue",
          "r", "ê", "m", "ng", "n"]
SYLL = {i + f for i in INITIALS for f in FINALS}
TONED = {"ā": ("a", 1), "á": ("a", 2), "ǎ": ("a", 3), "à": ("a", 4), "ē": ("e", 1), "é": ("e", 2), "ě": ("e", 3), "è": ("e", 4),
         "ī": ("i", 1), "í": ("i", 2), "ǐ": ("i", 3), "ì": ("i", 4), "ō": ("o", 1), "ó": ("o", 2), "ǒ": ("o", 3), "ò": ("o", 4),
         "ū": ("u", 1), "ú": ("u", 2), "ǔ": ("u", 3), "ù": ("u", 4), "ǖ": ("ü", 1), "ǘ": ("ü", 2), "ǚ": ("ü", 3), "ǜ": ("ü", 4)}
MARK = {"a": "āáǎà", "e": "ēéěè", "i": "īíǐì", "o": "ōóǒò", "u": "ūúǔù", "ü": "ǖǘǚǜ"}


def strip_tone(s):
    base, tone = "", 0
    for c in s:
        if c in TONED:
            b, t = TONED[c]
            base += b
            tone = t
        else:
            base += c
    return base, tone


def add_tone(base, t):
    if t == 0:
        return base
    for v in ("a", "e"):
        if v in base:
            return base.replace(v, MARK[v][t - 1], 1)
    if "ou" in base:
        return base.replace("o", MARK["o"][t - 1], 1)
    idx = max(i for i, c in enumerate(base) if c in "aeiouü")
    return base[:idx] + MARK[base[idx]][t - 1] + base[idx + 1:]


def segment(py, n):
    """Split toned pinyin into exactly n syllables; None if impossible/ambiguous."""
    s = py.lower().replace(" ", "").replace("'", "").replace("’", "")
    bases = [strip_tone(c)[0] for c in s]  # per char
    plain = "".join(bases)
    sols = []

    def rec(i, acc):
        if len(sols) > 1:
            return
        if i == len(s):
            if len(acc) == n:
                sols.append(list(acc))
            return
        if len(acc) >= n:
            return
        for j in range(min(len(s), i + 6), i, -1):
            if plain[i:j] in SYLL:
                syl = s[i:j]
                # each syllable has at most one tone mark
                if sum(1 for c in syl if c in TONED) <= 1:
                    rec(j, acc + [syl])
    rec(0, [])
    if len(sols) != 1:
        # prefer the solution where every syllable but the first carries a vowel start rule; give up if ambiguous
        return sols[0] if sols and all(x == sols[0] for x in sols) else None
    return sols[0]


def zh_tones():
    entries = {e["id"] for c in load("book", "mandarin")["chapters"] if c["id"] == "zh.tones"
               for e in c["entries"]}
    used = {i.get("prompt") for i in load("quiz", "mandarin") if i["entry"].startswith("zh.tones.")}
    items = []
    for v in load("vocab", "mandarin"):
        w, py = v["w"], v.get("py")
        if not py or w in used or not 1 <= len(w) <= 2 or not all("一" <= c <= "鿿" for c in w):
            continue
        # The dictionary tone isn't the spoken one: 一 and 不 change, 3+3 is
        # said 2+3, 儿 merges. The audio would contradict the key.
        if "一" in w or "不" in w or "儿" in w[1:]:
            continue
        syl = segment(py, len(w))
        if not syl or any(not re.search("[aeiouü]", strip_tone(s)[0]) for s in syl):
            continue
        tones = [strip_tone(s)[1] for s in syl]
        if tones[0] == 0 or tones == [3, 3]:
            continue
        entry = f"zh.tones.t{tones[0]}" if len(w) == 1 else f"zh.tones.c{tones[0]}{tones[1]}"
        if entry not in entries:
            continue
        steps = []
        for i, (c, s) in enumerate(zip(w, syl)):
            base, t = strip_tone(s)
            opts = [add_tone(base, k) for k in (1, 2, 3, 4)] + ([base] if i > 0 else [])
            steps.append({"prompt": c, "options": opts, "answer": (t - 1) if t else 4})
        items.append({"id": f"gen.{entry}.{w}", "entry": entry, "format": "tone-tap", "prompt": w,
                      "speak": w, "gloss": v.get("en"), "why": "".join(syl), "steps": steps})
    return items


def main():
    for lang, items in (("german", de_gender()), ("french", fr_gender()), ("mandarin", zh_tones())):
        path = CUR / f"gen-{lang}.json"
        lines = ",\n".join(json.dumps(i, ensure_ascii=False) for i in items)
        path.write_text("[\n" + lines + "\n]\n")
        print(f"{path.name}: {len(items)} items")


if __name__ == "__main__":
    main()
