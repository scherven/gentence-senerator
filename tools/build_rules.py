#!/usr/bin/env python3
"""Write Curriculum/rules-<lang>.json: the rules quizzes, one item per book
entry, made from what the entry already holds (head → group · tag). The
sentence quizzes in quiz-<lang>.json are the tests.

    python3 tools/build_rules.py && python3 tools/check_book.py

Deterministic: the same book gives the same file. Chapters without a fact to
ask (particles, register, tenses) get none.
"""
import json, pathlib, random, re

ROOT = pathlib.Path(__file__).resolve().parent.parent
CUR = ROOT / "gentence-senerator/gentence-senerator/Curriculum"
GAP = "＿"

# Other prepositions a German verb or adjective takes. Kept out of its
# distractors, since each would also be right.
DE_ALSO = {
    "sich freuen": {"auf", "über"}, "halten": {"für", "von", "zu"}, "bestehen": {"auf", "aus"},
    "sprechen": {"mit", "von", "über"}, "erzählen": {"über", "von"}, "sich bedanken": {"für", "bei"},
    "sich beschweren": {"bei", "über"}, "sich entschuldigen": {"bei", "für"},
    "sich bewerben": {"bei", "für", "um"}, "arbeiten": {"bei", "mit", "an"}, "leiden": {"an", "unter"},
    "denken": {"über", "an"}, "sich entscheiden": {"gegen", "für"}, "fragen": {"um", "nach"},
    "gehören": {"in", "zu"}, "riechen": {"an", "nach"}, "träumen": {"von"},
    "sich interessieren": {"für"}, "sich ärgern": {"über"}, "teilnehmen": {"an"},
    "die Diskussion": {"über", "um"}, "neugierig": {"auf"}, "die Frage": {"nach"},
}
DE_PREPS = ["auf", "an", "über", "für", "von", "mit", "zu", "nach", "vor", "um", "bei", "unter", "aus", "in"]

# What follows the French verb: without it, aider, oublier, arrêter… also take
# a direct noun object and the item has two answers.
FR_OBJ = {"commencer": "inf.", "aider": "inf.", "apprendre": "inf.", "réussir": "inf.", "hésiter": "inf.",
          "s'habituer": "inf.", "penser": "qn", "inviter": "inf.", "se mettre": "inf.", "répondre": "qn",
          "téléphoner": "qn", "ressembler": "qn", "finir": "inf.", "essayer": "inf.", "décider": "inf.",
          "arrêter": "inf.", "oublier": "inf.", "refuser": "inf.", "accepter": "inf.", "choisir": "inf.",
          "éviter": "inf.", "se souvenir": "qc", "s'occuper": "qc", "rêver": "inf.", "regarder": "qc",
          "écouter": "qc", "attendre": "qc", "chercher": "qc", "vouloir": "inf.", "pouvoir": "inf.",
          "devoir": "inf.", "aimer": "inf.", "espérer": "inf.", "préférer": "inf.", "savoir": "inf.",
          "payer": "qc", "être content": "inf.", "être capable": "inf.", "être prêt": "inf."}
# Everyday usage disagrees with the book's answer.
FR_SKIP = {"c'est difficile"}


def item(entry, fmt, prompt=None, steps=(), gloss=None, why=None, accept=None, speak=None):
    out = {"id": "rule." + entry["id"], "entry": entry["id"], "format": fmt}
    if prompt is not None: out["prompt"] = prompt
    if gloss: out["gloss"] = gloss
    if why: out["why"] = why
    if speak: out["speak"] = speak
    if steps: out["steps"] = list(steps)
    if accept: out["accept"] = accept
    return out


def step(options, answer, prompt=None):
    s = {"options": options, "answer": options.index(answer)}
    if prompt: s["prompt"] = prompt
    return s


def pick(rng, answer, pool, n):
    """`answer` and up to n-1 others from `pool`, shuffled."""
    others = sorted({p for p in pool if p != answer})
    rng.shuffle(others)
    opts = [answer] + others[:n - 1]
    rng.shuffle(opts)
    return opts


def card(e, back, detail=None, speak=None):
    return item(e, "card", prompt=e["head"], accept=[back], gloss=detail, speak=speak)


# ---------------------------------------------------------------- German

def de_prep(ch, rng):
    heads = {}
    for e in ch["entries"]:
        heads.setdefault(e["head"], set()).add(e["group"])
    for e in ch["entries"]:
        h, p = e["head"], e["group"]
        valid = heads[h] | DE_ALSO.get(h, set())
        opts = pick(rng, p, [x for x in DE_PREPS if x not in valid], 4)
        yield item(e, "two-step", f"{h} {GAP} + {GAP}", gloss=e.get("gloss"),
                   steps=[step(opts, p, "preposition"), step(["AKK", "DAT"], e["tag"], "case")],
                   why=f"{p} + {e['tag']}")


def de_fixed(ch, rng):
    for e in ch["entries"]:
        if e.get("group") in ("AKK", "DAT"):
            yield item(e, "flip", f"{e['head']} + {GAP}", gloss=e.get("gloss"),
                       steps=[step(["AKK", "DAT"], e["tag"])])


def de_aux(ch, rng):
    for e in ch["entries"]:
        yield item(e, "flip", f"{e['head']}: {GAP}", gloss=e.get("gloss") or e.get("group"),
                   steps=[step(["HABEN", "SEIN"], e["tag"])], why=e.get("reading"))


def de_reflexive(ch, rng):
    for e in ch["entries"]:
        yield item(e, "flip", f"{e['head']}: {GAP}", gloss=e.get("gloss"),
                   steps=[step(["AKK", "DAT"], e["tag"])], why=e.get("reading"))


def de_separable(ch, rng):
    for e in ch["entries"]:
        if "·" in e["head"] or not e.get("reading"):
            continue
        yield card(e, e["reading"], e.get("gloss"))


def de_gender(ch, rng):
    for e in ch["entries"]:
        yield item(e, "pick-one", f"{GAP} {e['head']}", gloss=e.get("gloss"),
                   steps=[step(["der", "die", "das"], e["tag"])])


def de_connectors(ch, rng):
    groups = sorted({e["group"] for e in ch["entries"] if e.get("group")})
    for e in ch["entries"]:
        if e.get("group") and len(groups) >= 3:
            yield item(e, "pick-one", f"{e['head']} → {GAP}", gloss=e.get("gloss"),
                       steps=[step(groups, e["group"])])


# ---------------------------------------------------------------- French

def fr_aux(ch, rng):
    for e in ch["entries"]:
        yield item(e, "flip", f"{e['head']} → {GAP}", gloss=e.get("gloss"),
                   steps=[step(["ÊTRE", "AVOIR"], e["tag"])], why=e.get("reading"))


def fr_prep(ch, rng):
    for e in ch["entries"]:
        h = re.sub(r"\s+(à|de)$", "", e["head"].split(",")[0].strip())
        if e.get("point") == "adjectives-prepositions":
            h = ("c'est " if h.startswith("difficile") else "être ") + h
        if h in FR_SKIP or h not in FR_OBJ:
            continue
        yield item(e, "pick-one", f"{h} {GAP} + {FR_OBJ[h]}", gloss=e.get("gloss"),
                   steps=[step(["à", "de", "Ø"], e["group"])])


def fr_places(ch, rng):
    by_group = {}
    for e in ch["entries"]:
        by_group.setdefault(e["group"], set()).add(e["tag"].lower())
    for e in ch["entries"]:
        rest = e["head"].split(" + ", 1)
        if len(rest) != 2:
            continue
        opts = sorted(by_group[e["group"]])
        if not 3 <= len(opts) <= 4:
            continue
        yield item(e, "pick-one", f"{GAP} + {rest[1]}", gloss=e["group"],
                   steps=[step(opts, e["tag"].lower())], why=e.get("reading"))


def fr_gender(ch, rng):
    for e in ch["entries"]:
        head = re.sub(r"\s*→.*$", "", e["head"])
        yield item(e, "flip", f"{GAP} {head}", steps=[step(["le", "la"], e["tag"].lower())],
                   why=e.get("gloss"))


# ---------------------------------------------------------------- Mandarin

def zh_measure(ch, rng):
    usable = [e for e in ch["entries"] if "·" not in e["head"]]
    for e in usable:
        pool = [o["head"] for o in usable if o.get("group") != e.get("group")]
        yield item(e, "pick-one", f"一{GAP}", gloss=e.get("gloss"),
                   steps=[step(pick(rng, e["head"], pool, 4), e["head"])], why=e.get("reading"))


def zh_negation(ch, rng):
    for e in ch["entries"]:
        h, t = e["head"], e.get("tag")
        if t in ("不", "没") and h.startswith(t) and len(h) > 1:
            yield item(e, "flip", GAP + h[1:], gloss=e.get("gloss"), steps=[step(["不", "没"], t)])


# Sentence-final particles close some heads (…吗); as options they are no test.
PARTICLES = {"吗", "了", "的", "吧", "呢", "啊"}


def frame_parts(head):
    parts = [p.strip("，, ") for p in head.replace("...", "…").split("…")]
    parts = [p for p in parts if p]
    return parts if len(parts) == 2 else None


def zh_frames(chapters, rng):
    entries = [e for ch in chapters for e in ch["entries"] if frame_parts(e["head"])]
    seconds_of = {}
    for e in entries:
        a, b = frame_parts(e["head"])
        seconds_of.setdefault(a, set()).add(b)
    # Stand-ins: 也 / 都 after most concessives, the buts for each other.
    groups = [{"也", "都"}, {"但", "但是", "可是", "却", "而"}]
    swap = {x: g for g in groups for x in g}
    for e in entries:
        a, b = frame_parts(e["head"])
        if re.search(r"[，,]", b):
            continue
        bad = seconds_of[a] | swap.get(b, set())
        pool = [x for x in (frame_parts(o["head"])[1] for o in entries)
                if x not in bad and x not in PARTICLES and len(x) <= 3 and not re.search(r"[，,]", x)]
        yield item(e, "pick-one", f"{a}…{GAP}…", gloss=e.get("gloss"),
                   steps=[step(pick(rng, b, pool, 4), b)], why=e.get("reading"))


def zh_cards(ch, rng):
    for e in ch["entries"]:
        if ch["id"].endswith("word-building") and e.get("group") not in ("SUFFIX", "PREFIX"):
            continue
        yield card(e, e["gloss"], e.get("reading"), speak=e["head"].strip("—"))


PLAN = {
    "german": {"de.verb-prep": de_prep, "de.noun-adj-prep": de_prep, "de.fixed-preps": de_fixed,
               "de.perfekt-aux": de_aux, "de.reflexive": de_reflexive, "de.separable": de_separable,
               "de.gender": de_gender, "de.connectors": de_connectors},
    "french": {"fr.etre-avoir": fr_aux, "fr.verb-prep": fr_prep, "fr.places": fr_places,
               "fr.gender": fr_gender},
    "mandarin": {"zh.measure": zh_measure, "zh.negation": zh_negation,
                 "zh.adv-idioms": zh_cards, "zh.adv-idioms-more": zh_cards,
                 "zh.adv-word-building": zh_cards},
}
ZH_FRAMES = ["zh.structures", "zh.linked", "zh.adv-conditions", "zh.adv-concession", "zh.adv-reasons"]


def build(lang):
    book = json.loads((CUR / f"book-{lang}.json").read_text())
    chapters = {c["id"]: c for c in book["chapters"]}
    rng = random.Random(7)
    items = []
    for cid, fn in PLAN[lang].items():
        if cid in chapters:
            items += list(fn(chapters[cid], rng))
    if lang == "mandarin":
        items += list(zh_frames([chapters[c] for c in ZH_FRAMES if c in chapters], rng))
    return items


def main():
    for lang in PLAN:
        items = build(lang)
        path = CUR / f"rules-{lang}.json"
        path.write_text(json.dumps(items, ensure_ascii=False, indent=1) + "\n")
        print(f"{path.name}: {len(items)} items")


if __name__ == "__main__":
    main()
