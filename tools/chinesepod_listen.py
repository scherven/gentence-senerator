#!/usr/bin/env python3
"""Turn the dialogues from chinesepod_dialogues.py into listen-mode passages.

    python3 tools/chinesepod_listen.py asr   [--src DIR]
    python3 tools/chinesepod_listen.py brief [--src DIR]
    python3 tools/chinesepod_listen.py check LLLL ...
    python3 tools/chinesepod_listen.py build [--src DIR] [--audio all | 1660 1664 ...]

    asr    Whisper word timings per recording -> tools/chinesepod/asr/LLLL.json
    brief  one file per dialogue for whoever writes the enrichment: the OCR
           lines next to what Whisper heard -> tools/chinesepod/brief/LLLL.txt
    check  validate enrichment files and compare them to the OCR and to Whisper
    build  OCR lines + enrichment + timings -> the app's Dialogues/ folder

Enrichment is tools/chinesepod/enrich/LLLL.json, written by hand or by a model
from the brief (see ENRICH below). It fixes OCR, orders the lines as spoken,
splits each line into words with pinyin and a gloss, and adds the setup, the
gist questions and the chunks. Build refuses a file whose words don't spell
its lines.

Everything this writes is gitignored: the text and audio are ChinesePod's.
Each stage caches per lesson; Ctrl-C and rerun resumes. Needs ffmpeg and
mlx-whisper.
"""

import argparse
import difflib, glob, json, os, re, signal, subprocess, sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
WORK = os.path.join(HERE, "chinesepod")
APP = os.path.join(HERE, "..", "gentence-senerator", "gentence-senerator", "Dialogues")
SRC = os.path.expanduser("~/Downloads/chinesepod/dialogues")
WHISPER = "mlx-community/whisper-large-v3-turbo"
CJK = re.compile(r"[㐀-鿿0-9]")
NAME = re.compile(r"^(\d+) - (\d+) (.+?)(?: \(Part \d\))?$")

ENRICH = """
{
  "title": "Transferring Money",
  "speakers": {"A": "Teller", "B": "Customer", "C": "Sister"},
  "setup": "One short English sentence: where, who. No spoilers.",
  "lines": [
    {"speaker": "A", "english": "...",
     "words": [{"w": "你好", "py": "nǐ hǎo", "g": "hello"}, {"w": "，"}, ...]}
  ],
  "gist": [{"q": "她转了多少钱？", "en": "How much does she send?",
            "options": ["一千块", "一万块", "十万块"], "answer": 1, "line": 7}],
  "chunks": ["转账", "手续费"]
}
lines: in the order spoken; a line's text is its words joined. Punctuation is
a word with no py. py is contextual (tone sandhi on 一/不, neutral tones, 儿
merged). line in gist is 1-based. gist questions and options are Chinese at the
lesson's level, en is the question in English; no question may give away
another's answer. chunks are words that appear in the lines.
"""

STOPPING = False


def _stop(signum, frame):
    global STOPPING
    if STOPPING:
        raise KeyboardInterrupt
    STOPPING = True
    print("\nstopping after this lesson; progress is saved (Ctrl-C again to abort)",
          file=sys.stderr)


signal.signal(signal.SIGINT, _stop)


def lessons(src):
    """(lesson number, stem, title, has audio), by file order."""
    out = []
    for txt in sorted(glob.glob(os.path.join(src, "*.txt"))):
        stem = os.path.basename(txt)[:-4]
        m = NAME.match(stem)
        if not m:
            continue
        out.append((m.group(2), stem, m.group(3),
                    os.path.exists(os.path.join(src, stem + ".m4a"))))
    return out


def save(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def load(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def ocr_lines(src, stem):
    rows = []
    with open(os.path.join(src, stem + ".txt"), encoding="utf-8") as f:
        for raw in f.read().strip().split("\n"):
            parts = raw.split("\t")
            parts += [""] * (3 - len(parts))
            rows.append({"speaker": parts[0].strip(), "text": parts[1].strip(),
                         "english": parts[2].strip()})
    return rows


# MARK: asr


def stage_asr(src):
    import mlx_whisper
    todo = [(n, stem) for n, stem, _, audio in lessons(src)
            if audio and not os.path.exists(os.path.join(WORK, "asr", n + ".json"))]
    print(f"asr: {len(todo)} to do")
    for n, stem in todo:
        if STOPPING:
            break
        r = mlx_whisper.transcribe(os.path.join(src, stem + ".m4a"), path_or_hf_repo=WHISPER,
                                   language="zh", word_timestamps=True,
                                   initial_prompt="以下是普通话的对话。",
                                   # Conditioning on earlier text sends long clips
                                   # into repetition loops (2051: 直直直…).
                                   condition_on_previous_text=False)
        words = [[w["word"], round(w["start"], 3), round(w["end"], 3)]
                 for s in r["segments"] for w in s.get("words", [])]
        save(os.path.join(WORK, "asr", n + ".json"), {"words": words, "onset": onset(src, stem)})
        print(f"  {stem}: {len(words)} words")


def pcm(path, rate=16000):
    raw = subprocess.run(["ffmpeg", "-v", "quiet", "-i", path, "-ac", "1", "-ar", str(rate),
                          "-f", "s16le", "-"], capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.int16).astype(np.float32) / 32768


def onset(src, stem):
    """First speech, by energy. Whisper's first word stamp is often seconds late."""
    x = pcm(os.path.join(src, stem + ".m4a"))
    hop = 160
    n = len(x) // hop
    db = 20 * np.log10(np.sqrt((x[:n * hop].reshape(n, hop) ** 2).mean(1)) + 1e-9)
    db = np.convolve(db, np.ones(5) / 5, "same")
    loud = np.nonzero(db > np.percentile(db, 15) + 12)[0]
    return round(max(0.0, loud[0] / 100 - 0.1), 2) if len(loud) else 0.0


# MARK: brief


def stage_brief(src):
    for n, stem, title, audio in lessons(src):
        path = os.path.join(WORK, "brief", n + ".txt")
        heard = ""
        asr = os.path.join(WORK, "asr", n + ".json")
        if os.path.exists(asr):
            heard = "".join(w[0] for w in load(asr)["words"])
        rows = ocr_lines(src, stem)
        body = [f"Lesson {n}: {title}", f"Audio: {'yes' if audio else 'none (text only)'}", "",
                "OCR lines (speaker / Chinese / English), as read off the slide:"]
        body += [f"{i + 1:2d}\t{r['speaker'] or '?'}\t{r['text']}\t{r['english']}"
                 for i, r in enumerate(rows)]
        if heard:
            body += ["", "What Whisper heard, in spoken order (may mishear; trust the OCR "
                     "for characters, trust this for order and missing lines):", heard]
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write("\n".join(body) + "\n")
    print(f"brief: {os.path.join(WORK, 'brief')}")


# MARK: build


def level(n):
    """ChinesePod's own label, by lesson range, on this app's HSK scale."""
    return 5 if int(n) >= 2000 else 4


def check(n, enr):
    errs = []
    for i, line in enumerate(enr["lines"]):
        if not line.get("words"):
            errs.append(f"line {i + 1}: no words")
        if line.get("speaker") not in enr["speakers"]:
            errs.append(f"line {i + 1}: speaker {line.get('speaker')!r} not in speakers")
    for q in enr["gist"]:
        if not (0 <= q["answer"] < len(q["options"])):
            errs.append(f"gist {q['q']!r}: answer out of range")
        if not (1 <= q["line"] <= len(enr["lines"])):
            errs.append(f"gist {q['q']!r}: line out of range")
        if not re.search(r"[\u4e00-\u9fff]", q["q"]) or not q.get("en"):
            errs.append(f"gist {q['q']!r}: question must be Chinese, with `en`")
    text = "".join(w["w"] for l in enr["lines"] for w in l["words"])
    for c in enr["chunks"]:
        if c not in text:
            errs.append(f"chunk {c} not in the dialogue")
    return errs


def stage_check(src, only):
    for n, stem, title, audio in lessons(src):
        if only and n not in only:
            continue
        path = os.path.join(WORK, "enrich", n + ".json")
        if not os.path.exists(path):
            print(f"{n}: no enrichment")
            continue
        try:
            enr = load(path)
            errs = check(n, enr)
        except (ValueError, KeyError, TypeError) as e:
            print(f"{n}: unreadable: {e!r}")
            continue
        ours = "".join(c for l in enr["lines"] for w in l["words"] for c in w["w"] if CJK.match(c))
        ocr = "".join(c for r in ocr_lines(src, stem) for c in r["text"] if CJK.match(c))
        vs_ocr = difflib.SequenceMatcher(None, ours, ocr, autojunk=False).ratio()
        line = f"{n}: {len(enr['lines'])} lines, {vs_ocr:.0%} like the OCR"
        asr_path = os.path.join(WORK, "asr", n + ".json")
        if os.path.exists(asr_path):
            line += f", {time(json.loads(json.dumps(enr)), load(asr_path)):.0%} timed"
        print(line + ("; " + "; ".join(errs) if errs else "; OK"))


def time(enr, asr):
    """Word and line timings from Whisper, matched to the enrichment's text by
    character diff. Characters Whisper missed get no time; a word gets one if
    any of its characters did."""
    heard, stamp = [], []
    for w, a, b in asr["words"]:
        cs = [c for c in w if CJK.match(c)]
        for i, c in enumerate(cs):
            heard.append(c)
            stamp.append((a + (b - a) * i / len(cs), a + (b - a) * (i + 1) / len(cs)))
    ours, where = [], []
    for li, line in enumerate(enr["lines"]):
        for wi, w in enumerate(line["words"]):
            for c in w["w"]:
                if CJK.match(c):
                    ours.append(c)
                    where.append((li, wi))
    at = {}
    for a, b, k in difflib.SequenceMatcher(None, ours, heard, autojunk=False).get_matching_blocks():
        for j in range(k):
            at.setdefault(where[a + j], []).append(stamp[b + j])

    covered = sum(len(v) for v in at.values())
    spans = []
    for li, line in enumerate(enr["lines"]):
        for wi, w in enumerate(line["words"]):
            ts = at.get((li, wi))
            if ts:
                w["start"], w["end"] = round(ts[0][0], 2), round(ts[-1][1], 2)
        ts = [t for wi in range(len(line["words"])) for t in at.get((li, wi), [])]
        spans.append([ts[0][0], ts[-1][1]] if ts else None)

    # Lines: start a little early, end a little late, never overlap, and a line
    # Whisper missed entirely inherits the gap between its neighbours.
    spans[0] = [asr.get("onset", 0.0), spans[0][1]] if spans[0] else spans[0]
    for i, s in enumerate(spans):
        if s is None:
            prev = spans[i - 1][1] if i and spans[i - 1] else asr.get("onset", 0.0)
            nxt = next((t[0] for t in spans[i + 1:] if t), prev + 2)
            spans[i] = [prev, nxt]
        else:
            s[0] -= 0.12
            s[1] += 0.25
    for i in range(1, len(spans)):
        if spans[i][0] < spans[i - 1][1]:
            mid = (spans[i][0] + spans[i - 1][1]) / 2
            spans[i][0] = spans[i - 1][1] = mid
    for line, s in zip(enr["lines"], spans):
        line["start"], line["end"] = round(max(0, s[0]), 2), round(s[1], 2)
    return covered / max(1, len(ours))


def encode(src, stem, out):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", os.path.join(src, stem + ".m4a"),
                    "-ac", "1", "-c:a", "aac", "-b:a", "64k", out], check=True)


def stage_build(src, bundle):
    os.makedirs(APP, exist_ok=True)
    passages, report = [], []
    for n, stem, title, audio in lessons(src):
        path = os.path.join(WORK, "enrich", n + ".json")
        if not os.path.exists(path):
            report.append(f"{n} {title}: no enrichment; skipped")
            continue
        enr = load(path)
        errs = check(n, enr)
        if errs:
            report.append(f"{n} {title}: " + "; ".join(errs))
            continue
        asr_path = os.path.join(WORK, "asr", n + ".json")
        cover = time(enr, load(asr_path)) if audio and os.path.exists(asr_path) else None
        file = None
        if audio and ("all" in bundle or n in bundle):
            file = f"cp-{n}.m4a"
            if not os.path.exists(os.path.join(APP, file)):
                encode(src, stem, os.path.join(APP, file))
        lines = [{"n": i + 1, "speaker": l["speaker"],
                  "text": "".join(w["w"] for w in l["words"]), "english": l["english"],
                  "start": l.get("start") if cover else None,
                  "end": l.get("end") if cover else None,
                  "words": [{k: w[k] for k in ("w", "py", "g", "start", "end")
                             if w.get(k) is not None and (cover or k not in ("start", "end"))}
                            for w in l["words"]]}
                 for i, l in enumerate(enr["lines"])]
        passages.append({
            "id": f"cp-{n}", "lesson": int(n), "language": "mandarin", "level": level(n),
            "title": enr.get("title") or title, "audio": file,
            "seconds": lines[-1]["end"] if cover else None,
            "setup": enr["setup"],
            "speakers": [{"id": k, "name": v} for k, v in enr["speakers"].items()],
            "lines": lines,
            "gist": [{"question": q["q"], "english": q.get("en"), "options": q["options"],
                      "answer": q["answer"], "line": q["line"]} for q in enr["gist"]],
            "chunks": enr["chunks"],
        })
        report.append(f"{n} {title}: {len(lines)} lines"
                      + (f", {cover:.0%} of characters timed" if cover is not None else ", text only")
                      + (", bundled" if file else ""))
    save(os.path.join(APP, "dialogues.json"), passages)
    print("\n".join(report))
    print(f"build: {len(passages)} passages -> {APP}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stage", choices=["asr", "brief", "check", "build"])
    ap.add_argument("only", nargs="*", help="lesson numbers, for check")
    ap.add_argument("--src", default=SRC)
    ap.add_argument("--audio", nargs="*", default=["1660"],
                    help="lesson numbers whose audio goes into the app")
    a = ap.parse_args()
    {"asr": lambda: stage_asr(a.src), "brief": lambda: stage_brief(a.src),
     "check": lambda: stage_check(a.src, set(a.only)),
     "build": lambda: stage_build(a.src, set(a.audio))}[a.stage]()


if __name__ == "__main__":
    main()
