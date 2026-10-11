#!/usr/bin/env python3
"""Review-quality eval: replays the app's real review request (prompt, schema,
level framing) for each scenario in scenarios.json across model/effort arms,
then has a judge model score every review against hand-written ground truth.

    # 1. write requests.json from the Swift source (ReviewRequestDump test)
    xcodebuild ... test -only-testing:gentence-seneratorTests/ReviewRequestDump
    # 2. run
    python3 tools/eval/review_eval.py submit --run pilot --scenarios de-weil zh-bu-mei fr-clean-ne
    python3 tools/eval/review_eval.py wait --run pilot     # polls, collects, judges
    python3 tools/eval/review_eval.py report --run pilot

Everything goes through the Message Batches API (half price, as in the app).
State lives in tools/eval/runs/<run>/state.json and is written after every
step, so Ctrl-C or a crash loses nothing; rerun the same command to resume.
`--cap` (dollars, default 10) is checked against money already spent in
every run plus a projection before anything is submitted.
"""
import argparse, json, os, re, signal, ssl, sys, time, urllib.request, urllib.error

try:  # python.org builds ship without a CA store
    import certifi
    CTX = ssl.create_default_context(cafile=certifi.where())
except ImportError:
    CTX = None

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
KEYFILE = os.path.join(ROOT, "secrets", "key.swift")
RUNS = os.path.join(HERE, "runs")
API = "https://api.anthropic.com/v1"

# $/M tokens: input, output. Batch halves everything; cache writes 1.25x input,
# cache reads 0.1x input.
PRICES = {
    "claude-opus-5": (5.0, 25.0),
    "claude-opus-5-5": (4.0, 20.0),
    "claude-sonnet-5-5": (2.0, 10.0),
    "claude-haiku-5-5": (0.10, 0.50),
}
ARMS = {
    "opus5-high": ("claude-opus-5", "high"),        # what ships today
    "opus55-high": ("claude-opus-5-5", "high"),
    "opus55-medium": ("claude-opus-5-5", "medium"),
    "sonnet55-high": ("claude-sonnet-5-5", "high"),
    "sonnet55-medium": ("claude-sonnet-5-5", "medium"),
    "haiku55-high": ("claude-haiku-5-5", "high"),
}
JUDGE = ("claude-opus-5-5", "high")


def cost(model, usage):
    pin, pout = PRICES[model]
    toks = (usage.get("input_tokens", 0) * pin
            + usage.get("cache_creation_input_tokens", 0) * pin * 1.25
            + usage.get("cache_read_input_tokens", 0) * pin * 0.1
            + usage.get("output_tokens", 0) * pout)
    return toks / 1e6 * 0.5


def load_key():
    txt = open(KEYFILE).read()
    m = re.search(r'anthropicKey\s*=\s*"([^"]+)"', txt)
    if not m:
        sys.exit(f"no anthropicKey in {KEYFILE}")
    return m.group(1)


def http(method, path, body=None, raw=False):
    req = urllib.request.Request(path if path.startswith("http") else API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None)
    req.add_header("x-api-key", KEY)
    req.add_header("anthropic-version", "2023-06-01")
    req.add_header("content-type", "application/json")
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=300, context=CTX) as r:
                data = r.read()
            return data.decode() if raw else json.loads(data)
        except urllib.error.HTTPError as e:
            detail = e.read().decode()[:500]
            if e.code in (429, 500, 502, 503, 529) and attempt < 4:
                time.sleep(5 * (attempt + 1)); continue
            sys.exit(f"{method} {path}: {e.code} {detail}")
        except (urllib.error.URLError, TimeoutError):
            if attempt < 4:
                time.sleep(5 * (attempt + 1)); continue
            raise


# ---------- state ----------

def state_path(run):
    return os.path.join(RUNS, run, "state.json")


def load_state(run):
    p = state_path(run)
    return json.load(open(p)) if os.path.exists(p) else {"batches": {}, "results": {}, "judged": {}, "spent": 0.0}


def save_state(run, st):
    os.makedirs(os.path.dirname(state_path(run)), exist_ok=True)
    tmp = state_path(run) + ".tmp"
    json.dump(st, open(tmp, "w"), ensure_ascii=False, indent=1)
    os.replace(tmp, state_path(run))


def spent_everywhere():
    total = 0.0
    if os.path.isdir(RUNS):
        for run in os.listdir(RUNS):
            if os.path.exists(state_path(run)):
                total += load_state(run).get("spent", 0.0)
    return total


# ---------- submit ----------

def submit(args):
    reqs = json.load(open(os.path.join(HERE, "requests.json")))
    scen = {s["id"]: s for s in json.load(open(os.path.join(HERE, "scenarios.json")))}
    ids = args.scenarios or list(scen)
    arms = args.arms or list(ARMS)
    st = load_state(args.run)
    # Projection: per-call cost from finished results where known, else a
    # conservative guess, plus the judge.
    guess = {"claude-opus-5": 0.12, "claude-opus-5-5": 0.10, "claude-sonnet-5-5": 0.05, "claude-haiku-5-5": 0.005}
    seen = {}
    for run in (os.listdir(RUNS) if os.path.isdir(RUNS) else []):
        for cid, r in load_state(run).get("results", {}).items():
            seen.setdefault(cid.split("__")[0], []).append(r["cost"])
    projected = 0.0
    for arm in arms:
        if arm in st["batches"]:
            continue
        per = (sum(seen[arm]) / len(seen[arm])) if seen.get(arm) else guess[ARMS[arm][0]]
        projected += per * len(ids) + 0.03 * len(ids)
    already = spent_everywhere()
    print(f"spent so far ${already:.2f}; this submit projected ${projected:.2f}; cap ${args.cap:.2f}")
    if already + projected > args.cap:
        sys.exit("over the cap; submit fewer arms or scenarios")
    for arm in arms:
        if arm in st["batches"]:
            print(f"{arm}: already submitted"); continue
        model, effort = ARMS[arm]
        batch = []
        for sid in ids:
            p = json.loads(json.dumps(reqs[sid]))
            p["model"] = model
            p["output_config"]["effort"] = effort
            batch.append({"custom_id": f"{arm}__{sid}", "params": p})
        b = http("POST", "/messages/batches", {"requests": batch})
        st["batches"][arm] = {"id": b["id"], "kind": "review", "model": model}
        st.setdefault("scenarios", ids)
        save_state(args.run, st)
        print(f"{arm}: {b['id']} ({len(batch)} requests)")


# ---------- collect ----------

def text_of(msg):
    return "".join(b.get("text", "") for b in msg.get("content", []) if b.get("type") == "text")


def collect(run, st):
    """Pulls any ended batch. Returns True when every batch has ended."""
    done = True
    for name, b in list(st["batches"].items()):
        if b.get("collected"):
            continue
        info = http("GET", f"/messages/batches/{b['id']}")
        if info["processing_status"] != "ended":
            done = False
            print(f"  {name}: {info['processing_status']} {info['request_counts']}")
            continue
        lines = http("GET", info["results_url"], raw=True).splitlines()
        for line in lines:
            if not line.strip():
                continue
            row = json.loads(line)
            cid, res = row["custom_id"], row["result"]
            entry = {"type": res["type"]}
            if res["type"] == "succeeded":
                msg = res["message"]
                entry.update(usage=msg["usage"], stop=msg.get("stop_reason"),
                             cost=cost(b["model"], msg["usage"]), text=text_of(msg))
                st["spent"] += entry["cost"]
            else:
                entry.update(cost=0.0, error=res.get("error"))
            (st["judged"] if b["kind"] == "judge" else st["results"])[cid] = entry
        b["collected"] = True
        save_state(run, st)
        print(f"  {name}: collected {len(lines)}")
    return done


# ---------- judge ----------

JUDGE_SYSTEM = """You are a native-level teacher of the language in question, auditing an
automated tutor's review of a learner's answer. Be exact and fair. You are
given the learner's answer, the errors a teacher planted or verified in it
(possibly none), and the tutor's findings.

For each expected error: did any problem finding (verdict breaks or weakens)
identify it, and is that finding's fix correct?

For every problem finding that does not correspond to an expected error,
classify it: "real" (a genuine error the answer key missed), "invented"
(the learner's usage is correct or acceptable to a native speaker),
"preference" (a stylistic alternative presented as an error), or
"duplicate" (same issue as another finding).

Count problem findings whose `locate` text gives away the correction
(names the right form or the exact fix); `locate` is shown first so the
learner can self-repair, and must say only where.

If you think the answer key itself is wrong, say so in key_concerns.
`usefulness` is 1-10: how much this review would help this learner, given
accuracy, clarity, and fit to their level."""

JUDGE_SCHEMA = {
    "type": "object",
    "properties": {
        "expected": {"type": "array", "items": {"type": "object", "properties": {
            "index": {"type": "integer"}, "caught": {"type": "boolean"}, "fix_correct": {"type": "boolean"}},
            "required": ["index", "caught", "fix_correct"], "additionalProperties": False}},
        "extras": {"type": "array", "items": {"type": "object", "properties": {
            "finding": {"type": "integer"},
            "class": {"type": "string", "enum": ["real", "invented", "preference", "duplicate"]},
            "why": {"type": "string"}},
            "required": ["finding", "class", "why"], "additionalProperties": False}},
        "locate_leaks": {"type": "integer"},
        "key_concerns": {"type": "string"},
        "usefulness": {"type": "integer"},
        "comment": {"type": "string"},
    },
    "required": ["expected", "extras", "locate_leaks", "key_concerns", "usefulness", "comment"],
    "additionalProperties": False,
}


def judge_facts(s, review):
    finds = []
    for i, f in enumerate(review.get("findings", [])):
        finds.append({"index": i, **{k: f.get(k) for k in ("verdict", "weight", "kind", "locate", "name", "fix", "note")}})
    expected = "\n".join(f"{i}. {e}" for i, e in enumerate(s["expect"])) or "None: the answer key says this answer is correct."
    return (f"Language: {s['lang']}\nLevel: {s['level']}\nMode: {s['mode']}\n"
            f"Spoken: {'no, typed' if s['typed'] else 'yes'}\n"
            f"Asked: {s.get('target') or ''} {s.get('english') or ''}\n"
            f"Learner said: {s['said']}\n\nExpected errors:\n{expected}\n\n"
            f"Tutor score: {review.get('score')}\nTutor natural version: {review.get('natural')}\n"
            f"Tutor findings:\n{json.dumps(finds, ensure_ascii=False, indent=1)}")


def submit_judge(run, st):
    if "judge" in st["batches"]:
        return
    scen = {s["id"]: s for s in json.load(open(os.path.join(HERE, "scenarios.json")))}
    batch = []
    for cid, r in st["results"].items():
        if r["type"] != "succeeded":
            continue
        try:
            review = json.loads(r["text"])
        except json.JSONDecodeError:
            continue
        model, effort = JUDGE
        batch.append({"custom_id": cid, "params": {
            "model": model, "max_tokens": 8000,
            "system": [{"type": "text", "text": JUDGE_SYSTEM, "cache_control": {"type": "ephemeral"}}],
            "messages": [{"role": "user", "content": judge_facts(scen[cid.split("__")[1]], review)}],
            "output_config": {"effort": effort, "format": {"type": "json_schema", "schema": JUDGE_SCHEMA}},
        }})
    if not batch:
        return
    b = http("POST", "/messages/batches", {"requests": batch})
    st["batches"]["judge"] = {"id": b["id"], "kind": "judge", "model": JUDGE[0]}
    save_state(run, st)
    print(f"judge: {b['id']} ({len(batch)} requests)")


def wait(args):
    st = load_state(args.run)
    while True:
        if collect(args.run, st):
            if "judge" not in st["batches"]:
                submit_judge(args.run, st)
                continue
            break
        print(f"waiting... spent ${st['spent']:.2f}")
        time.sleep(args.every)
    print(f"all collected; run spent ${st['spent']:.2f}")


# ---------- report ----------

GLITCH = re.compile(r'\ninstead:|\\u00|u00[0-9a-f]{2}|f"ur|\?\?')


def report(args):
    # Several runs pool into one table; ids are prefixed so repeats stay apart.
    st = {"results": {}, "judged": {}, "spent": 0.0}
    for run in args.run:
        one = load_state(run)
        st["spent"] += one["spent"]
        for part in ("results", "judged"):
            for cid, v in one[part].items():
                arm, sid = cid.split("__")
                st[part][f"{arm}__{sid}__{run}"] = v
    scen = {s["id"]: s for s in json.load(open(os.path.join(HERE, "scenarios.json")))}
    rows = {}
    for cid, r in st["results"].items():
        arm, sid, _ = cid.split("__")
        a = rows.setdefault(arm, {"n": 0, "cost": 0.0, "out": 0, "caught": 0, "expected": 0, "fixok": 0,
                                  "invented": 0, "pref": 0, "real": 0, "clean_ok": 0, "clean_n": 0,
                                  "leaks": 0, "useful": [], "fail": 0, "glitch": 0})
        a["n"] += 1
        a["cost"] += r["cost"]
        if r["type"] != "succeeded":
            a["fail"] += 1; continue
        a["out"] += r["usage"]["output_tokens"]
        try:
            review = json.loads(r["text"])
        except json.JSONDecodeError:
            a["fail"] += 1; continue
        # The app rejects these and regrades (Tutor.read).
        if not review.get("findings") and review.get("score", 0) < 50:
            a["fail"] += 1
        if GLITCH.search(r["text"]):
            a["glitch"] += 1
        j = st["judged"].get(cid)
        if not j or j["type"] != "succeeded":
            continue
        v = json.loads(j["text"])
        s = scen[sid]
        a["expected"] += len(s["expect"])
        a["caught"] += sum(1 for e in v["expected"] if e["caught"])
        a["fixok"] += sum(1 for e in v["expected"] if e["caught"] and e["fix_correct"])
        inv = sum(1 for x in v["extras"] if x["class"] == "invented")
        a["invented"] += inv
        a["pref"] += sum(1 for x in v["extras"] if x["class"] == "preference")
        a["real"] += sum(1 for x in v["extras"] if x["class"] == "real")
        if not s["expect"]:
            a["clean_n"] += 1
            a["clean_ok"] += 1 if inv == 0 and not any(x["class"] == "preference" for x in v["extras"]) else 0
        a["leaks"] += v["locate_leaks"]
        a["useful"].append(v["usefulness"])
    hdr = f"{'arm':16} {'caught':>8} {'fix ok':>7} {'clean ok':>9} {'invent':>7} {'pref':>5} {'leaks':>6} {'useful':>7} {'fail':>5} {'out tok':>8} {'$/review':>9}"
    print(hdr); print("-" * len(hdr))
    for arm in [a for a in ARMS if a in rows]:
        a = rows[arm]
        u = sum(a["useful"]) / len(a["useful"]) if a["useful"] else 0
        print(f"{arm:16} {a['caught']:>3}/{a['expected']:<4} {a['fixok']:>7} {a['clean_ok']:>4}/{a['clean_n']:<4} "
              f"{a['invented']:>7} {a['pref']:>5} {a['leaks']:>6} {u:>7.1f} {a['fail']:>5} "
              f"{a['out'] // max(a['n'], 1):>8} {a['cost'] / max(a['n'], 1):>9.4f}")
    jc = sum(j.get("cost", 0) for j in st["judged"].values())
    print(f"\nthese runs spent ${st['spent']:.2f} (judge ${jc:.2f}); all runs ${spent_everywhere():.2f}")
    if args.detail:
        for cid in sorted(st["judged"]):
            j = st["judged"][cid]
            if j["type"] == "succeeded":
                v = json.loads(j["text"])
                bad = [x for x in v["extras"] if x["class"] in ("invented", "preference")]
                missed = [e for e in v["expected"] if not e["caught"]]
                if bad or missed or v["key_concerns"].strip():
                    print(f"\n{cid}: missed {[e['index'] for e in missed]}; "
                          f"{'; '.join(x['class'] + ': ' + x['why'] for x in bad)}"
                          f"{'; KEY: ' + v['key_concerns'] if v['key_concerns'].strip() else ''}")


def main():
    global KEY
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("submit"); s.add_argument("--run", required=True)
    s.add_argument("--arms", nargs="+", choices=list(ARMS)); s.add_argument("--scenarios", nargs="+")
    s.add_argument("--cap", type=float, default=10.0)
    w = sub.add_parser("wait"); w.add_argument("--run", required=True); w.add_argument("--every", type=int, default=60)
    r = sub.add_parser("report"); r.add_argument("--run", nargs="+", required=True); r.add_argument("--detail", action="store_true")
    args = ap.parse_args()
    KEY = load_key()
    signal.signal(signal.SIGINT, lambda *_: sys.exit("\ninterrupted; state is saved, rerun to resume"))
    {"submit": submit, "wait": wait, "report": report}[args.cmd](args)


if __name__ == "__main__":
    main()
