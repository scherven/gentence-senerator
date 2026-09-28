#!/usr/bin/env python3
"""Replay the prompt-generation call outside the app, to check its variety.

Reconstructs Tutor.generateSystem + Tutor.nextPrompt's `facts` and DayPlan's
seed/domain rotation exactly as they ship, samples a day's draw the way
Store.refreshPlan does, and runs a whole day's session per mode against the
live Messages API. Use it to see what a single day actually asks — whether
translate spans varied settings and produce asks real questions — without
paying for the calls through the app or eyeballing one prompt at a time.

Kept because generation is hard to test through the app: the day-draw, the
seed rotation and the model all sit between a tap and a sentence. Ports of the
Swift live in Curriculum/grammar-*.json's neighbours — grep the identifiers
here against Tutor.swift / DayPlan.swift if a prompt changes and this drifts.

Needs the API key from gentence-senerator/gentence-senerator/key.swift, and it
hits the live API — a full run is 60 calls. Writes results incrementally to
--out and handles Ctrl-C, so an interrupted run keeps what it got.

    python3 tools/prompt_variety.py                 # translate + produce, 3 langs
    python3 tools/prompt_variety.py --modes translate --langs french
"""
import argparse, json, os, re, signal, sys, time, random, urllib.request, urllib.error

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = os.path.join(ROOT, "gentence-senerator", "gentence-senerator")
CUR = os.path.join(APP, "Curriculum")
KEYFILE = os.path.join(APP, "key.swift")
M64 = (1 << 64) - 1

LANG_NAME = {"mandarin": "Mandarin", "german": "German", "french": "French"}
GEN_NOTES = {
    "mandarin": "Write the English prompt so a natural Mandarin rendering needs the\ntarget structure. No Chinese in the English prompt.",
    "german": "No German in the English prompt.",
    "french": "No French in the English prompt.",
}
LEVELS = {"french": 2, "german": 2, "mandarin": 3}

# --- port of DayPlan.swift: lifeDomains, seed, domain (seeded xorshift + FNV-1a) ---
LIFE_DOMAINS = ["work", "family", "food and cooking", "money", "sleep", "travel",
                "a daily habit", "the weekend", "health or the body", "studying",
                "the neighbourhood or commute", "the home", "a friend", "childhood or the past"]

def _hash(*parts):
    h = 1469598103934665603
    for p in parts:
        for b in p.encode("utf-8"):
            h = ((h ^ b) * 1099511628211) & M64
        h = ((h ^ 0x2f) * 1099511628211) & M64
    return h

def _shuffled(items, seed):
    a, state = list(items), (seed or 0x9E3779B97F4A7C15)
    def nxt():
        nonlocal state
        state ^= (state << 13) & M64
        state ^= (state >> 7)
        state ^= (state << 17) & M64
        return state & M64
    i = len(a) - 1
    while i > 0:
        j = nxt() % (i + 1)
        a[i], a[j] = a[j], a[i]
        i -= 1
    return a

def domain(day, lang, turn):
    order = _shuffled(LIFE_DOMAINS, _hash(day, lang))
    return order[turn % len(order)]

def seed_word(have, new, turn):
    pool = list(have) + list(new)
    return None if not pool or turn % 3 == 2 else pool[turn % len(pool)]

# --- ports of the Swift that feeds the call ---
def level_label(lang, n):
    if lang == "mandarin":
        return f"HSK {min(max(n, 1), 9)}"
    return ["A1", "A2", "B1", "B2", "C1", "C2"][min(max(n - 1, 0), 5)]

def voice(lang):
    return (f"You are a {LANG_NAME[lang]} tutor. Everything you write to the\n"
            "learner is terse and plain. Lead with the fix or the fact. Short\n"
            "sentences; if one clause will do, use one. No em-dash asides. No \"not X\n"
            "but Y\" or \"X, not Y\" framing. No pep talk, praise filler or reassurance.\n"
            "Do not restate the learner's sentence or your own point. No metaphors.")

def generate_system(lang):
    n = LANG_NAME[lang]
    return f"""{voice(lang)}

You write one thing for the learner to attempt.

translate — `english` is a sentence to render in {n};
leave `target` null. Write it so a natural rendering needs the target
structure, rather than naming the structure.

listen — `target` is the sentence to be played, written first and in
{n}; `english` is its meaning.

produce — `target` is a question to answer in {n},
written first and in {n}; `english` is its meaning.
Exactly one question about the learner's own life: one sentence, one
question mark, under fifteen words. No preamble, no second question, no
"and why?". Answerable in two or three sentences.
Decide what is worth asking before you think about grammar at all. Pick
a corner of their life — work, family, food, money, sleep, travel, a
habit, someone they have not called — and ask what you would actually
ask a person about it. A structure you are pointed at is at most
something the answer may happen to need; it is never the reason for the
question, and a question that exists to host one is the wrong question.
Land somewhere new each time: two questions about the same place, or
the same afternoon, are one question asked twice however different the
words.

Sentences are things a person would actually say. No textbook filler, no
sentences that exist only to contain a grammar point.
{GEN_NOTES[lang]}
Latency-sensitive — the learner is waiting on a blank screen. Begin the
reply immediately."""

def build_facts(mode, lang, level, stretch, seed, dom, avoid):
    facts = f"Mode: {mode}\nLevel: {level_label(lang, level)}"
    if stretch:
        if mode != "produce":
            facts += f"\nWrite this so a natural rendering needs {stretch['name']}.\n{stretch['instruction']}"
        else:
            facts += (f"\nIf the answer happens to want {stretch['name']} — {stretch['instruction']} — "
                      "so much the better. Do not go looking for a topic that would need it. "
                      "Ask what you would have asked anyway.")
    if dom:
        facts += (f"\nSet this in one ordinary corner of a life — this time: {dom}. A "
                  "different corner each turn; two sentences about the same setting are one sentence.")
    if seed:
        if mode == "produce":
            facts += f"\nOne word may slip into the question unremarked, if it fits, or not at all: {seed}"
        else:
            facts += (f"\nA word to work in only where it fits, and to leave out entirely where it "
                      f"does not — never what the sentence is about: {seed}\n"
                      "In translate the English has to call for it; do not name it.")
    if avoid:
        facts += ("\nAlready asked today. Do not repeat one, and do not ask a different "
                  "question about the same setting either — go somewhere else in their life: "
                  + " | ".join(avoid[-20:]))
    return facts

PROMPT_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "english": {"type": "string", "description": "The English side. For translate this is what the learner reads; elsewhere it is the gloss."},
        "target": {"type": ["string", "null"], "description": "The target-language side: the sentence to be played, or the question to be answered — for produce, one sentence ending in a single question mark. Null for translate."},
    },
    "required": ["english", "target"],
}

def load_key():
    txt = open(KEYFILE).read()
    m = re.search(r'anthropicKey\s*[:=]\s*"([^"]+)"', txt) or re.search(r'"(sk-[^"]+)"', txt)
    if not m:
        sys.exit(f"could not parse an API key from {KEYFILE}")
    return m.group(1)

def load_json(name):
    return json.load(open(os.path.join(CUR, name)))

def pick_stretch(points, level, rng, use="spoken"):
    cand = [p for p in points if p["level"] <= level and not p.get("formulaic", False)
            and p.get("use", "both") in ("both", use)]
    if not cand:
        return None
    weights = [1.0 / (1 + level - p["level"]) for p in cand]
    return rng.choices(cand, weights=weights, k=1)[0]

def word_seeds(words, level, rng, each=2):
    band = [w for w, b in words.items() if b <= level]
    above = [w for w, b in words.items() if b == level + 1]
    return rng.sample(band, min(each, len(band))), rng.sample(above, min(each, len(above)))

def call(key, system, facts):
    body = json.dumps({
        "model": "claude-opus-5", "max_tokens": 8000,
        "system": [{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
        "messages": [{"role": "user", "content": facts}],
        "output_config": {"effort": "low", "format": {"type": "json_schema", "schema": PROMPT_SCHEMA}},
        "fallbacks": "default",
    }).encode()
    req = urllib.request.Request("https://api.anthropic.com/v1/messages", data=body, method="POST")
    for h, val in [("x-api-key", key), ("anthropic-version", "2023-06-01"),
                   ("anthropic-beta", "server-side-fallback-2026-07-01"),
                   ("content-type", "application/json")]:
        req.add_header(h, val)
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                obj = json.loads(r.read())
            if obj.get("stop_reason") == "refusal":
                return {"refusal": (obj.get("stop_details") or {}).get("explanation", "?")}
            text = "".join(b.get("text", "") for b in obj.get("content", []) if b.get("type") == "text")
            return json.loads(text)
        except urllib.error.HTTPError as e:
            detail = e.read().decode()[:300]
            if e.code in (429, 500, 503, 529) and attempt < 3:
                time.sleep(3 * (attempt + 1)); continue
            return {"error": f"{e.code}: {detail}"}
        except Exception as e:
            if attempt < 3:
                time.sleep(2 * (attempt + 1)); continue
            return {"error": str(e)}
    return {"error": "exhausted"}

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--modes", nargs="+", default=["translate", "produce"], choices=["translate", "produce"])
    ap.add_argument("--langs", nargs="+", default=["french", "german", "mandarin"], choices=list(LANG_NAME))
    ap.add_argument("--turns", type=int, default=10)
    ap.add_argument("--day", default="2026-09-24", help="the yyyy-MM-dd the domain order keys on")
    ap.add_argument("--seed", type=int, default=20260913, help="RNG seed for the day's draw")
    ap.add_argument("--out", default=os.path.join(ROOT, "prompt_variety_results.json"))
    args = ap.parse_args()

    key = load_key()
    results = {"config": vars(args), "runs": []}
    def flush():
        json.dump(results, open(args.out, "w"), ensure_ascii=False, indent=2)
    def on_sigint(*_):
        flush(); print(f"\ninterrupted — saved to {args.out}"); sys.exit(130)
    signal.signal(signal.SIGINT, on_sigint)

    rng = random.Random(args.seed)
    draws = {}
    for lang in args.langs:
        level = LEVELS[lang]
        stretch = pick_stretch(load_json(f"grammar-{lang}.json"), level, rng)
        have, new = word_seeds(load_json(f"words-{lang}.json").get("words", {}), level, rng)
        draws[lang] = (level, stretch, have, new)

    for lang in args.langs:
        level, stretch, have, new = draws[lang]
        system = generate_system(lang)
        for mode in args.modes:
            run = {"lang": lang, "mode": mode, "level": level_label(lang, level),
                   "seeds_have": have, "seeds_new": new, "turns": []}
            avoid = []
            for t in range(args.turns):
                offered = stretch if (mode == "produce" and t == 0) else None
                seed = seed_word(have, new, t)
                dom = domain(args.day, lang, t) if mode == "translate" else None
                out = call(key, system, build_facts(mode, lang, level, offered, seed, dom, avoid))
                eng, tgt = out.get("english"), out.get("target")
                run["turns"].append({"t": t, "english": eng, "target": tgt, "seed": seed,
                                     "domain": dom, "error": out.get("error") or out.get("refusal")})
                if eng:
                    avoid.append(eng)
                tag = f"seed={seed or '—'}" + (f" dom={dom}" if dom else "")
                print(f"[{lang}/{mode} {t+1}/{args.turns}] {tag}\n     "
                      + (f"{tgt}\n     = {eng}" if tgt else str(eng)), flush=True)
                flush()
            results["runs"].append(run)
    flush()
    print(f"\nDONE — {args.out}")

if __name__ == "__main__":
    main()
