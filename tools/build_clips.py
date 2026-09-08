#!/usr/bin/env python3
"""Build the listen-mode clip manifest from a CC0 speech corpus.

Both supported corpora ship sentence-level audio with *human* transcripts, so
no forced alignment is needed — that is the whole reason they were chosen. ASR
is not accurate enough to be ground truth in any of these languages, and a
learner marked wrong for being right is the worst failure this app has.

    python3 tools/build_clips.py --corpus common-voice \
        --root ~/corpora/cv-de --language german --level 2 --count 200

Writes Clips/clips.json and copies the audio next to it. Resumable: progress is
checkpointed after every clip, and Ctrl-C leaves a usable manifest behind.
"""

import argparse, csv, json, os, shutil, signal, sys, wave
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import clipselect

STOPPING = False


def _stop(signum, frame):
    global STOPPING
    STOPPING = True
    print("\n  stopping after this clip; progress is saved", file=sys.stderr)


signal.signal(signal.SIGINT, _stop)

LICENCES = {"common-voice": "CC0", "voxpopuli": "CC0"}
# CC0 needs no credit. Anything added later that is not CC0 does, and the app
# reads this field to decide whether to show an acknowledgements screen.
ATTRIBUTION = {"common-voice": None, "voxpopuli": None}


def exact_durations(root: Path):
    """Common Voice ships measured durations; the size estimate below is only
    for corpora that do not."""
    tsv = root / "clip_durations.tsv"
    if not tsv.exists():
        return {}
    out = {}
    with tsv.open(encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            values = list(row.values())
            try:
                out[values[0]] = float(values[1]) / 1000.0
            except (ValueError, IndexError):
                pass
    return out


def duration(path: Path) -> float:
    try:
        if path.suffix.lower() == ".wav":
            with wave.open(str(path)) as w:
                return w.getnframes() / float(w.getframerate())
    except Exception:
        pass
    # mp3 and friends: fall back to a size estimate rather than pulling in a
    # dependency. Only used for filtering, never shown.
    return path.stat().st_size / 16000.0


def load_checkpoint(path: Path):
    if path.exists():
        with path.open() as f:
            state = json.load(f)
        print(f"  resuming: {len(state['clips'])} already done")
        return state
    return {"clips": [], "seen": []}


def save_checkpoint(path: Path, state):
    tmp = path.with_suffix(".tmp")
    with tmp.open("w") as f:
        json.dump(state, f)
    tmp.replace(path)


def rows_common_voice(root: Path):
    """validated.tsv only — the clips other contributors have confirmed."""
    tsv = root / "validated.tsv"
    if not tsv.exists():
        sys.exit(f"expected {tsv}. Point --root at an extracted Common Voice bundle.")
    with tsv.open(encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            yield row["path"], row["sentence"]


def rows_voxpopuli(root: Path):
    """asr_*.tsv, whose transcripts are human and semi-spontaneous."""
    tsvs = sorted(root.glob("asr_*.tsv"))
    if not tsvs:
        sys.exit(f"no asr_*.tsv under {root}")
    for tsv in tsvs:
        with tsv.open(encoding="utf-8") as f:
            for row in csv.DictReader(f, delimiter="\t"):
                text = (row.get("normalized_text") or row.get("raw_text") or "").strip()
                if text:
                    yield row["id"] + ".ogg", text


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--corpus", choices=["common-voice", "voxpopuli"], required=True)
    p.add_argument("--root", type=Path, required=True)
    p.add_argument("--language", choices=["mandarin", "german", "french"], required=True)
    p.add_argument("--level", type=int, default=None,
                   help="Stamp every clip with this level instead of deriving one. "
                        "Deriving is almost always what you want.")
    p.add_argument("--count", type=int, default=200)
    p.add_argument("--min-seconds", type=float, default=1.2)
    p.add_argument("--max-seconds", type=float, default=8.0)
    p.add_argument("--out", type=Path, default=Path("gentence-senerator/gentence-senerator/Clips"))
    args = p.parse_args()

    args.out.mkdir(parents=True, exist_ok=True)
    checkpoint = args.out / ".build-state.json"
    state = load_checkpoint(checkpoint)
    seen = set(state["seen"])

    audio_root = args.root / "clips" if args.corpus == "common-voice" else args.root
    rows = rows_common_voice(args.root) if args.corpus == "common-voice" else rows_voxpopuli(args.root)

    measured = exact_durations(args.root)
    print("reading the corpus…")
    candidates = []
    for name, text in rows:
        seconds = measured.get(name)
        if seconds is None:
            source = audio_root / name
            if not source.exists():
                continue
            seconds = duration(source)
        candidates.append((name, text, seconds))
    print(f"  {len(candidates)} recordings")

    chosen = clipselect.choose(
        candidates, args.language, args.count,
        min_seconds=args.min_seconds, max_seconds=args.max_seconds,
    )
    print(f"  chose {len(chosen)}")

    for name, text, seconds, level in chosen:
        if STOPPING:
            break
        if name in seen:
            continue
        seen.add(name)

        source = audio_root / name
        if not source.exists():
            continue

        clip_id = f"{args.corpus}-{args.language}-{len(state['clips']):05d}"
        target_name = clip_id + source.suffix
        shutil.copy2(source, args.out / target_name)

        state["clips"].append({
            "id": clip_id,
            "language": args.language,
            "text": text,
            "english": None,          # filled by --gloss, or left for the app
            "file": target_name,
            "seconds": round(seconds, 2),
            "level": args.level if args.level is not None else level,
            "attribution": ATTRIBUTION[args.corpus],
            "licence": LICENCES[args.corpus],
        })
        state["seen"] = sorted(seen)
        save_checkpoint(checkpoint, state)
        if len(state["clips"]) % 25 == 0:
            print(f"  {len(state['clips'])} clips")

    manifest = args.out / "clips.json"
    existing = []
    if manifest.exists():
        with manifest.open() as f:
            existing = [c for c in json.load(f)
                        if not c["id"].startswith(f"{args.corpus}-{args.language}-")]
    with manifest.open("w") as f:
        json.dump(existing + state["clips"], f, ensure_ascii=False, indent=1)

    print(f"wrote {manifest} — {len(existing) + len(state['clips'])} clips total")
    if not STOPPING:
        checkpoint.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
