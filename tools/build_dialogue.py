#!/usr/bin/env python3
"""Turn a screenshot of a dialogue into a listening passage.

    python3 tools/build_dialogue.py --images ~/Desktop/cinema.png \
        --language mandarin

Two stages, checkpointed between them:

    read   the image, into speaker/text/gloss lines
    build  the gaps and the quiz from those lines

Reading is saved before anything is built on it — check it by eye. Re-running
skips what is done; --redo forces a stage. Ctrl-C leaves the checkpoint usable.

No audio comes out of an image. `audio` and the line timings are written null
until a recording is attached.
"""

import argparse, base64, json, os, signal, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import clipselect

MODEL = "claude-opus-5"
MEDIA = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
         ".gif": "image/gif", ".webp": "image/webp"}

STOPPING = False


def _stop(signum, frame):
    global STOPPING
    STOPPING = True
    print("\n  stopping after this stage; progress is saved", file=sys.stderr)


signal.signal(signal.SIGINT, _stop)


# MARK: Checkpoint


def load_checkpoint(path):
    if path.exists():
        state = json.loads(path.read_text(encoding="utf-8"))
        done = [s for s in ("read", "build") if state.get(s)]
        if done:
            print(f"  resuming: {', '.join(done)} already done")
        return state
    return {}


def save_checkpoint(path, state):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(state, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(path)


# MARK: Model


def client():
    try:
        import anthropic
    except ImportError:
        sys.exit("pip install anthropic")
    if not (os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("ANTHROPIC_AUTH_TOKEN")):
        sys.exit("set ANTHROPIC_API_KEY")
    return anthropic.Anthropic()


def ask(api, system, content, schema):
    """Streamed: a long dialogue plus thinking outruns the non-streaming timeout."""
    with api.messages.stream(
        model=MODEL,
        max_tokens=16000,
        system=system,
        messages=[{"role": "user", "content": content}],
        thinking={"type": "adaptive"},
        output_config={"format": {"type": "json_schema", "schema": schema}},
    ) as stream:
        message = stream.get_final_message()
    if message.stop_reason == "refusal":
        sys.exit(f"the model declined: {message.stop_details}")
    text = next(b.text for b in message.content if b.type == "text")
    return json.loads(text)


def image_block(path):
    media = MEDIA.get(path.suffix.lower())
    if media is None:
        sys.exit(f"{path.name}: not an image I can send ({', '.join(sorted(MEDIA))})")
    return {"type": "image", "source": {
        "type": "base64", "media_type": media,
        "data": base64.standard_b64encode(path.read_bytes()).decode(),
    }}


# MARK: Stage 1 — read


READ_SYSTEM = """
You read a dialogue out of an image and write it down. You do not improve it.

Transcribe exactly what is printed, including punctuation. If the image shows
pinyin or a translation, use them; do not invent lines that are not there.
Speakers are single letters in the order they first speak: A, B, C.
`english` is what the line means, in natural English — not a gloss of each word.
`title` is two or three words naming the situation, in the target language.
"""


def read_schema():
    return {
        "type": "object", "additionalProperties": False,
        "required": ["title", "lines"],
        "properties": {
            "title": {"type": "string"},
            "lines": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "required": ["speaker", "text", "english"],
                "properties": {
                    "speaker": {"type": "string"},
                    "text": {"type": "string"},
                    "english": {"type": "string"},
                },
            }},
        },
    }


def stage_read(api, images, language):
    content = [image_block(p) for p in images]
    content.append({"type": "text", "text":
                    f"Write down this {language} dialogue, in order."})
    return ask(api, READ_SYSTEM, content, read_schema())


# MARK: Stage 2 — gaps and quiz


BUILD_SYSTEM = """
You build a listening exercise from a dialogue the learner will hear once
before seeing any text.

THE QUIZ comes first, on one uninterrupted listen, so every question must be
answerable from meaning alone — never from a detail only a reader would catch.
Four options. Exactly one is right.

Every wrong option must be TRUE OF A DIFFERENT LINE of this dialogue: a learner
who picks it has attached a real fact to the wrong place, and `optionLines`
records where each came from so the app can say which. A wrong option absent
from the dialogue is guessable. `line` is the line carrying the answer.

THE GAPS are the repair pass, shown only for lines whose question was missed.
One gap per question, on the word that question depends on — if the answer to
"why is he late" is in 堵车, the gap goes on 堵车 and nowhere else.

Three options per gap, the right one among them. They must be confusable BY EAR:
same syllable count, and differing in tone, in an initial or final that this
language's learners actually merge, or in nothing at all where the language has
homophones. Prefer a distractor that appears elsewhere in this dialogue — a real
word the learner has already heard beats an invented one.

A gap on a word that is obvious from the sentence around it tests reading, not
hearing. If the only candidates are like that, return fewer gaps.

`why` is shown to the learner after they answer that gap: one clause on what
makes the sound easy to lose. Name the sounds, not the exercise.

Write questions in the target language, with `english` alongside.
"""


def build_schema():
    return {
        "type": "object", "additionalProperties": False,
        "required": ["gaps", "quiz"],
        "properties": {
            "gaps": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "required": ["line", "answer", "options", "why"],
                "properties": {
                    "line": {"type": "integer", "description": "1-based."},
                    "answer": {"type": "string", "description": "Appears verbatim in that line."},
                    "options": {"type": "array", "items": {"type": "string"},
                                "description": "Three, including the answer."},
                    "why": {"type": "string", "description": "Shown to the learner."},
                },
            }},
            "quiz": {"type": "array", "items": {
                "type": "object", "additionalProperties": False,
                "required": ["question", "english", "options", "answer", "line", "optionLines"],
                "properties": {
                    "question": {"type": "string"},
                    "english": {"type": "string"},
                    "options": {"type": "array", "items": {"type": "string"},
                                "description": "Four."},
                    "answer": {"type": "integer", "description": "Index of the right one."},
                    "line": {"type": "integer", "description": "1-based line carrying the answer."},
                    "optionLines": {"type": "array", "items": {"type": "integer"},
                                    "description": "Per option, the line it is true of."},
                },
            }},
        },
    }


def stage_build(api, read, language, level, questions):
    numbered = "\n".join(
        f"{i + 1}. {ln['speaker']}: {ln['text']}   ({ln['english']})"
        for i, ln in enumerate(read["lines"])
    )
    ask_for = f"""
{language}, level {level}. {len(read['lines'])} lines.

{numbered}

Write {questions} questions, and one gap for each.
"""
    return ask(api, BUILD_SYSTEM, [{"type": "text", "text": ask_for}], build_schema())


# MARK: Assembly


def derive_level(lines, language, fallback):
    """Per line, then the hardest that the HSK list can actually place. A
    dialogue almost always contains something off the list, so `level_of` over
    the whole thing would return None every time."""
    levels = [lv for lv in
              (clipselect.level_of(ln["text"], language, {}) for ln in lines)
              if lv is not None]
    if not levels:
        return fallback
    levels.sort()
    return levels[int(len(levels) * 0.8)]


def check(read, build):
    """What a person would not catch by eye until a learner hit it."""
    complaints = []
    count = len(read["lines"])

    for gap in build["gaps"]:
        where = f"gap on line {gap['line']}"
        if not 1 <= gap["line"] <= count:
            complaints.append(f"{where}: no such line")
            continue
        if gap["answer"] not in read["lines"][gap["line"] - 1]["text"]:
            complaints.append(f"{where}: {gap['answer']!r} is not in that line")
        if gap["answer"] not in gap["options"]:
            complaints.append(f"{where}: the answer is not among the options")
        if len(set(gap["options"])) != len(gap["options"]):
            complaints.append(f"{where}: duplicate options")

    for i, q in enumerate(build["quiz"]):
        where = f"question {i + 1}"
        if not 0 <= q["answer"] < len(q["options"]):
            complaints.append(f"{where}: answer index out of range")
        if len(q["optionLines"]) != len(q["options"]):
            complaints.append(f"{where}: optionLines does not match options")
        if len(set(q["options"])) != len(q["options"]):
            complaints.append(f"{where}: duplicate options")
        # Each distractor is true of some line, and a wrong one must not be
        # true of the answer's line — that is what makes a wrong pick locatable.
        wrong = [ln for j, ln in enumerate(q["optionLines"]) if j != q["answer"]]
        if q["line"] in wrong:
            complaints.append(f"{where}: a wrong option is sourced from the answer's own line")
    return complaints


def assemble(read, build, language, level, dialogue_id):
    gaps = {g["line"]: g for g in build["gaps"]}
    lines = []
    for i, ln in enumerate(read["lines"], start=1):
        gap = gaps.get(i)
        lines.append({
            "n": i,
            "speaker": ln["speaker"],
            "text": ln["text"],
            "english": ln["english"],
            "startSeconds": None,
            "endSeconds": None,
            "gap": None if gap is None else {
                "answer": gap["answer"],
                "options": gap["options"],
                "why": gap["why"],
            },
        })
    quiz = [{
        "id": f"q{i + 1}",
        "question": q["question"],
        "english": q["english"],
        "options": q["options"],
        "answer": q["answer"],
        "line": q["line"],
        "optionLines": q["optionLines"],
    } for i, q in enumerate(build["quiz"])]

    return {
        "id": dialogue_id,
        "language": language,
        "level": level,
        "title": read["title"],
        "audio": None,
        "seconds": None,
        "speakers": sorted({ln["speaker"] for ln in read["lines"]}),
        "lines": lines,
        "quiz": quiz,
    }


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--images", type=Path, nargs="+", required=True,
                   help="Screenshots of one dialogue, in order.")
    p.add_argument("--language", choices=["mandarin", "german", "french"], required=True)
    p.add_argument("--id", default=None, help="Defaults to the first image's name.")
    p.add_argument("--level", type=int, default=None,
                   help="Stamp this level instead of deriving one from the text.")
    p.add_argument("--questions", type=int, default=5)
    p.add_argument("--redo", choices=["read", "build"], default=None)
    p.add_argument("--out", type=Path,
                   default=Path("gentence-senerator/gentence-senerator/Clips"))
    args = p.parse_args()

    for image in args.images:
        if not image.exists():
            sys.exit(f"no such image: {image}")

    dialogue_id = args.id or args.images[0].stem
    args.out.mkdir(parents=True, exist_ok=True)
    checkpoint = args.out / f".dialogue-{dialogue_id}.json"
    state = load_checkpoint(checkpoint)
    if args.redo:
        state.pop(args.redo, None)
        if args.redo == "read":
            state.pop("build", None)

    api = client()

    if not state.get("read"):
        print(f"reading {len(args.images)} image(s)…")
        state["read"] = stage_read(api, args.images, args.language)
        save_checkpoint(checkpoint, state)
        for i, ln in enumerate(state["read"]["lines"], start=1):
            print(f"  {i:>2}. {ln['speaker']}: {ln['text']}")
        print(f"  saved to {checkpoint} — check the lines before they are built on")

    if STOPPING:
        return

    level = args.level or derive_level(state["read"]["lines"], args.language, 3)

    if not state.get("build"):
        print(f"building {args.questions} questions and gaps at level {level}…")
        state["build"] = stage_build(api, state["read"], args.language,
                                     level, args.questions)
        save_checkpoint(checkpoint, state)

    complaints = check(state["read"], state["build"])
    if complaints:
        print("\nproblems — fix or re-run with --redo build:", file=sys.stderr)
        for c in complaints:
            print(f"  {c}", file=sys.stderr)

    passage = assemble(state["read"], state["build"], args.language, level, dialogue_id)

    manifest = args.out / "dialogues.json"
    existing = []
    if manifest.exists():
        existing = [d for d in json.loads(manifest.read_text(encoding="utf-8"))
                    if d["id"] != dialogue_id]
    manifest.write_text(
        json.dumps(existing + [passage], ensure_ascii=False, indent=1),
        encoding="utf-8")

    print(f"\nwrote {manifest} — {len(existing) + 1} passage(s)")
    print(f"  {len(passage['lines'])} lines, {len(passage['quiz'])} questions, "
          f"{sum(1 for l in passage['lines'] if l['gap'])} gaps, level {level}")
    print("  audio is null — attach a recording and fill in the line timings")
    if not complaints:
        checkpoint.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
