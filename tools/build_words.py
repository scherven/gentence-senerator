#!/usr/bin/env python3
"""Build the graded word lists the Lexicon loads.

Writes gentence-senerator/gentence-senerator/Curriculum/words-<language>.json,
one language at a time, so an interrupted run keeps whatever it finished.

Sources, both permissively licensed so the lists can ship inside the app:

  Mandarin  HSK 3.0 词汇表, levels 1-6. elkmovie/hsk30 wordlist.txt, MIT,
            (c) 2021 Pleco Inc. — their OCR of the official MOE PDF.
  German    OpenSubtitles 2018 frequency, bucketed by rank.
  French    OpenSubtitles 2018 frequency, bucketed by rank.
            Both from hermitdave/FrequencyWords, MIT.

The Goethe Wortlisten (A1-B1) and the CEFR référentiels are the graded lists
one would rather have, and neither is redistributable — they are (c) their
institutes. Rank buckets are the approximation we are allowed: a word one band
out is a slightly unusual word in a generated sentence, not a wrong lesson.
"""

import json
import os
import re
import sys
import tempfile
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "gentence-senerator", "gentence-senerator", "Curriculum")
CACHE = os.path.join(tempfile.gettempdir(), "gentence-words-cache")

HSK = "https://raw.githubusercontent.com/elkmovie/hsk30/main/wordlist.txt"
FREQ = "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/{0}/{0}_50k.txt"

# Rank -> CEFR band. The app numbers A1..C2 as 1..6.
BANDS = [(500, 1), (1200, 2), (2400, 3), (3800, 4), (5000, 5), (6000, 6)]


def fetch(url, name):
    """Cached on disk: a re-run after a failure does not re-download."""
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        print(f"  fetching {url}")
        with urllib.request.urlopen(url, timeout=120) as r:
            data = r.read()
        with open(path + ".part", "wb") as f:
            f.write(data)
        os.replace(path + ".part", path)
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(language, meta, words):
    os.makedirs(OUT, exist_ok=True)
    path = os.path.join(OUT, f"words-{language}.json")
    with open(path + ".part", "w", encoding="utf-8") as f:
        json.dump({"meta": meta, "words": words}, f,
                  ensure_ascii=False, sort_keys=True, indent=0)
    os.replace(path + ".part", path)
    per = {}
    for level in words.values():
        per[level] = per.get(level, 0) + 1
    print(f"  {path}: {len(words)} words, by band "
          + ", ".join(f"{k}:{per[k]}" for k in sorted(per)))


# MARK: Mandarin

HEADINGS = {"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7}
CJK = re.compile(r"^[㐀-䶿一-鿿〇]+$")


def mandarin():
    text = fetch(HSK, "hsk30-wordlist.txt")
    words, level = {}, None
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.endswith("词汇表"):
            level = HEADINGS.get(line[0])
            continue
        entry = re.match(r"^\d+\s+(.+)$", line)
        if entry is None or level is None or level > 6:
            continue
        # 爸爸｜爸 is two words; 白（形） is one with a part-of-speech note.
        for form in re.split(r"[｜|/]", entry.group(1)):
            form = re.sub(r"[（(][^）)]*[）)]", "", form).strip()
            if CJK.match(form):
                words.setdefault(form, level)
    write("mandarin", {
        "source": "HSK 3.0 词汇表 (official MOE list), levels 1-6",
        "via": "https://github.com/elkmovie/hsk30 wordlist.txt",
        "licence": "MIT, (c) 2021 Pleco Inc.",
        "bands": "HSK level, as published. Levels 7-9 are omitted: the list is "
                 "for seeding words into sentences, which is a low-level job.",
    }, words)


# MARK: German and French

# A subtitle corpus is dirty. Abbreviations keep their dot, elided clitics keep
# their apostrophe (c', l', qu'), and neither is a word to seed a sentence with.
TOKEN = re.compile(r"^[^\W\d_][\w'-]*$", re.UNICODE)
KEEP_SHORT = {"y", "à", "a", "on", "ou", "où", "et", "un", "je", "tu", "il"}


def band(rank):
    for limit, level in BANDS:
        if rank <= limit:
            return level
    return None


def frequency(language, code, name):
    text = fetch(FREQ.format(code), f"{code}_50k.txt")
    words, rank = {}, 0
    for line in text.splitlines():
        token = line.split(" ")[0].strip().lower()
        if not TOKEN.match(token) or token.endswith("'") or "." in token:
            continue
        if len(token) < 2 and token not in KEEP_SHORT:
            continue
        rank += 1
        level = band(rank)
        if level is None:
            break
        words.setdefault(token, level)
    write(language, {
        "source": f"{name} frequency, OpenSubtitles 2018 (Lison & Tiedemann), "
                  "top 6000 tokens after removing abbreviations, numerals and "
                  "elided clitics",
        "via": "https://github.com/hermitdave/FrequencyWords",
        "licence": "MIT",
        "bands": "Rank buckets, not an official syllabus: 1-500 A1, 501-1200 "
                 "A2, 1201-2400 B1, 2401-3800 B2, 3801-5000 C1, 5001-6000 C2. "
                 "The Goethe Wortlisten and the CEFR référentiels are graded "
                 "properly and are not redistributable.",
    }, words)


if __name__ == "__main__":
    only = sys.argv[1:] or ["mandarin", "german", "french"]
    if "mandarin" in only:
        print("mandarin")
        mandarin()
    if "german" in only:
        print("german")
        frequency("german", "de", "German")
    if "french" in only:
        print("french")
        frequency("french", "fr", "French")
