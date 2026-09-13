#!/usr/bin/env python3
"""Build the graded word lists the Lexicon loads.

Writes gentence-senerator/gentence-senerator/Curriculum/words-<language>.json,
one language at a time, so an interrupted run keeps whatever it finished.

Where the bands come from:

  Mandarin  HSK 3.0 词汇表, levels 1-6, as published. elkmovie/hsk30 wordlist.txt,
            MIT, (c) 2021 Pleco Inc. — their OCR of the official MOE PDF.

  German    Bands 1-3 are the Goethe-Institut Wortlisten for Goethe-Zertifikat
            A1 (Start Deutsch 1), A2 and B1 (DTZ), (c) Goethe-Institut e.V.,
            taken from two independent GitHub transcriptions of the official
            PDFs and unioned, because each one drops words the other has.
  French    Bands 1-3 are FLELex-Beacco, the CEFRLex resource that carries the
            expert levels of the Beacco et al. référentiels ("Niveau A1/A2/B1
            pour le français", Didier/CIEP) — (c) CENTAL, UCLouvain,
            CC BY-NC-SA 4.0.

  Both      Bands 4-6 have no official list at all, so they stay rank buckets
            over OpenSubtitles frequency (hermitdave/FrequencyWords, MIT),
            cleaned hard and with everything already banded 1-3 removed.

The cleaning matters more than the banding. hermitdave's lists are lower-cased,
so the capitalisation that would mark a name is gone and `alan` sits in the
German list looking like vocabulary. Every tail word therefore has to appear in
a dictionary of the language that excludes proper nouns by construction:

  German    enz/german-wordlist, CC0-1.0 — a Scrabble word list, so names,
            toponyms and abbreviations are excluded by its own rules.
  French    the Hunspell fr.dic shipped in LibreOffice/dictionaries (Dicollecte
            / Grammalecte, MPL 2.0), reading only its lower-case entries: French
            proper nouns are capitalised there, common words are not.

Both lists still leak — `Leslie` is in the German one, `blair` and `madison`
are lower-case entries in fr.dic — so a name database (smashew/NameDatabases,
Unlicense) drops what they miss. It takes `Faust` and `Mark` with it, which
costs nothing: the tail is cut to a fixed size, so a word dropped is one more
taken from further down the frequency list.

On top of that a tail word is dropped when it is an interjection, when it is
shorter than three letters, when it carries a hyphen or a space (the Lexicon
splits on non-letters, so such a word can never be matched and would be offered
forever), when it ranks five times better in the English list out of the same
corpus than it does here — which is a subtitle line nobody translated, and how
`girl` and `kids` were sitting in the German file — and when the Lexicon's own
suffix reduction, cascaded, already lands it on a word we hold: `häuser`
reduces to `haus` and `arbeitete` to `arbeit`, so holding either buys nothing.
"""

import json
import os
import re
import string
import sys
import tempfile
import unicodedata
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "gentence-senerator", "gentence-senerator", "Curriculum")
CACHE = os.path.join(tempfile.gettempdir(), "gentence-words-cache")

# Every source is pinned to a commit. A word list that changes under us is a
# lesson that changes under a learner.
HSK = ("https://raw.githubusercontent.com/elkmovie/hsk30/"
       "7f3d4fdcfcb6e826001df062747c943d1fa8160e/wordlist.txt")
FREQ = ("https://raw.githubusercontent.com/hermitdave/FrequencyWords/"
        "525f9b560de45753a5ea01069454e72e9aa541c6/content/2018/{0}/{0}_50k.txt")
# English out of the same corpus, to catch the lines nobody translated.
# A word ranking this many times better in English than here did not get here
# by being German or French: `girl`, `kids`, `look`, `out`, `take`.
IMPORTED = 5
# Goethe Wortlisten, transcribed from the official PDFs. Neither transcription
# is complete and they are incomplete in different places, so both are read.
GOETHE_TSV = ("https://raw.githubusercontent.com/ilkermeliksitki/"
              "goethe-institute-wordlist/"
              "cfef1c1ed3fdfa732c8b7dbeb0010f3d75c9c784/{level}/{letter}.tsv")
GOETHE_LIST = ("https://raw.githubusercontent.com/VitalyVorobyev/"
               "deutsch-textbook/"
               "438b7a172250b2889549007a3f4e4ad713061eaa/"
               "data/goethe-{level}-wortliste.txt")
FLELEX = ("https://raw.githubusercontent.com/nathanschulz/french-vocab-tool/"
          "ef4a836d62d5e4b8ed3abaefc5323d0d95b7a6a3/data/FleLex_TT_Beacco.tsv")
DE_WORDS = ("https://raw.githubusercontent.com/enz/german-wordlist/"
            "8436363e4cdb789815cf5084c431b43362bec7e5/words")
FR_DIC = ("https://raw.githubusercontent.com/LibreOffice/dictionaries/"
          "32b006a2c22a4ac7e8ed3f03346f7b3d85a970a4/fr_FR/dictionaries/fr.dic")
NAMES = ("https://raw.githubusercontent.com/smashew/NameDatabases/"
         "4a714a09ed69147c373d9b9f2bce20ef79a63381/"
         "NamesDatabases/first%20names/all.txt")

LETTERS = string.ascii_lowercase
# Bands 4-6, and how many words each gets off the top of the cleaned tail.
TAIL_BANDS = [(4, 800), (5, 800), (6, 800)]


class Missing(Exception):
    """A source we could not fetch. Named loudly rather than skipped."""

    def __init__(self, url, name, status=None):
        self.url, self.name, self.status = url, name, status
        super().__init__(url)

    def explain(self):
        why = f" (HTTP {self.status})" if self.status else ""
        print(f"  ! could not fetch {self.url}{why}")
        print(f"    download it by hand and save it as:")
        print(f"      {os.path.join(CACHE, self.name)}")
        print(f"    then run this script again; nothing was written for this "
              f"language, so the list already shipping is untouched.")


def fetch(url, name, encoding="utf-8"):
    """Cached on disk: a re-run after a failure does not re-download."""
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, name)
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        print(f"  fetching {url}")
        try:
            with urllib.request.urlopen(url, timeout=180) as r:
                data = r.read()
        except urllib.error.HTTPError as error:
            raise Missing(url, name, error.code)
        except (urllib.error.URLError, OSError):
            raise Missing(url, name)
        with open(path + ".part", "wb") as f:
            f.write(data)
        os.replace(path + ".part", path)
    with open(path, encoding=encoding, errors="replace") as f:
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


# MARK: What counts as a word at all

# The Lexicon splits an attempt on non-letters, so a word holding a space or a
# hyphen can never be matched, and one that is never matched is offered for
# ever. Letters, and nothing else.
WORD = re.compile(r"^[^\W\d_]+$", re.UNICODE)
KEEP_SHORT = {"y", "à", "a", "on", "ou", "où", "et", "un", "je", "tu", "il",
              "ab", "an", "da", "er", "es", "in", "ja", "je", "ob", "so",
              "um", "wo", "zu", "öl", "ei", "au", "ce", "de", "du", "en",
              "la", "le", "là", "me", "mi", "ne", "ni", "nu", "or", "os",
              "ré", "se", "si", "te"}

# Subtitles are people making noises at each other. None of these is a word to
# build a sentence around, and several sit high in the frequency list.
INTERJECTIONS = {
    "german": {"ah", "aah", "aaah", "ach", "aha", "oh", "ooh", "oho", "hm",
               "hmm", "hmmm", "mhm", "mmh", "mm", "äh", "ähm", "hä", "huch",
               "hey", "hei", "oje", "pff", "tja", "na", "nanu", "nee", "nö",
               "hoppla", "autsch", "aua", "wow", "boah", "uff", "puh",
               "igitt", "juhu", "oha", "jo", "yeah", "ok", "okay", "eh",
               "hu", "ha", "he", "uh", "uhh", "ups", "tss", "psst",
               "bla", "naja", "och", "ick", "hopp"},
    "french": {"ah", "aah", "oh", "ooh", "eh", "hé", "hein", "euh", "heu",
               "hum", "hmm", "mmm", "mm", "bah", "ben", "bof", "berk",
               "beurk", "brr", "bé", "clac", "da", "dia", "hop", "hou",
               "hue", "na", "ohé", "ouah", "ouh", "pff", "pfff", "toc",
               "vlan", "vertubleu", "pardi", "pardieu", "ô", "ouais", "las",
               "tchao", "hi", "ha", "hé", "ouf", "psst", "ok",
               "aïe", "oups", "miam", "beuh", "holà"},
}

REPEATED = re.compile(r"(.)\1\1")
VOWEL = re.compile(r"[aeiouyàâäåéèêëîïôöùûüœæ]")


# Slurs and strong vulgarity. A subtitle corpus is full of both, and these words
# get woven into generated practice sentences — the bar is what a teacher would
# put in front of a learner, not whether it is a real word. Applied to the tail
# only: the official Goethe and CEFR lists ship whole, so `blöd` (Goethe A2) and
# `baiser` (a kiss, and a CEFR headword) survive.
BLOCKED = {
    "german": {"neger", "schwuchtel", "fotze", "nutte", "hure", "schlampe", "fick",
               "ficken", "fickt", "arschloch", "arsch", "titten", "scheißkerl",
               "möse", "wichser", "pisse", "spast", "scheiße", "scheisse", "kacke"},
    "french": {"négro", "pédé", "tapette", "pute", "putain", "salope", "salopard",
               "bite", "enculé", "connard", "cul", "merde", "chier", "foutre",
               "chatte", "couilles", "nique", "niquer"},
}


def is_noise(word, language):
    """Transcribed noise: `chffffff`, `hmm`, and the standard interjections."""
    if word in INTERJECTIONS[language]:
        return True
    if REPEATED.search(word):
        return True
    return VOWEL.search(word) is None


def acceptable(word, language):
    if not WORD.match(word):
        return False
    if len(word) < 2 and word not in KEEP_SHORT:
        return False
    return not is_noise(word, language)


# MARK: The Lexicon's reduction, in Python
#
# The same endings as Bank.keys(for:in:) in Services/Lexicon.swift, but stripped
# in a cascade rather than once, and stopping at four letters rather than three.
# The Lexicon strips once because it has to be right about a single token; here
# the question is looser and answered offline — is this candidate another form
# of a word the list already holds? `arbeitete` reaches `arbeit` in two strips
# and `männern` reaches `mann`, and holding either alongside its infinitive is
# holding one word twice.
#
# It over-reaches sometimes: `piqûre` reaches `piquer`, and those are two words.
# Both are the same family though, so the learner meets it either way, and the
# tail is cut to a fixed size — one word dropped is one more taken from further
# down the frequency list, not one word fewer.

MINIMUM = 3
FAMILY_MINIMUM = 4
FAMILY_DEPTH = 3
ENDINGS = {
    "german": ["enden", "ende", "esten", "este", "est", "en", "em", "er",
               "es", "et", "st", "e", "t", "n", "s"],
    "french": ["eraient", "erions", "aient", "erais", "erait", "eront",
               "ions", "iez", "ais", "ait", "ant", "ent", "ons", "ez",
               "er", "ir", "re", "ees", "ee", "es", "s", "e"],
}


def fold(text):
    return "".join(c for c in unicodedata.normalize("NFD", text)
                   if not unicodedata.combining(c))


def family(word, language):
    """Every stem this word could be built on, itself included. The first strip
    is exactly the Lexicon's, so two words meeting there are two words the
    Lexicon already matches to each other; the cascade after it is this
    script's, and stops a letter later to keep `Ratte` away from `Rat`."""
    plain = word.lower()
    body = fold(plain)
    if language == "german" and body.startswith("ge") and len(body) - 2 >= MINIMUM:
        body = body[2:]
    stems = {plain, body}
    edge = {body}
    for ending in ENDINGS[language]:
        if body.endswith(ending) and len(body) - len(ending) >= MINIMUM:
            stems.add(body[:-len(ending)])
            edge.add(body[:-len(ending)])
    for _ in range(FAMILY_DEPTH):
        grown = set()
        for stem in edge:
            for ending in ENDINGS[language]:
                if stem.endswith(ending) and len(stem) - len(ending) >= FAMILY_MINIMUM:
                    shorter = stem[:-len(ending)]
                    if shorter not in stems:
                        stems.add(shorter)
                        grown.add(shorter)
        edge = grown
        if not edge:
            break
    return stems


# MARK: German — the Goethe-Institut Wortlisten

# `die Adresse, -n(2)` is one headword wearing a gender, a plural and a sense
# number. `(sich) freuen` is a verb wearing its reflexive.
SENSE = re.compile(r"\s*\(\d+\)\s*$")
PAREN = re.compile(r"\([^)]*\)")
ARTICLE = re.compile(r"^(der|die|das)\s+")


def headwords(raw):
    """Every bare headword in one cell of a Wortliste row."""
    line = PAREN.sub(" ", SENSE.sub("", raw.strip()))
    # A comma starts the plural or the principal parts: `ziehen, zieht, zog`.
    line = line.split(",")[0]
    out = []
    for part in re.split(r"/", line):
        part = ARTICLE.sub("", part.strip()).strip(" -–—")
        # `un-` is a prefix, not a word; `all-` is a determiner stem and is one.
        if len(part) >= MINIMUM or (len(part) >= 2 and "-" not in raw):
            out.append(part.lower())
    return out


def goethe_tsv(name):
    """One level of the per-letter transcription. Column one is the headword."""
    found = set()
    for letter in LETTERS:
        try:
            text = fetch(GOETHE_TSV.format(level=name, letter=letter),
                         f"goethe/{name}-{letter}.tsv")
        except Missing as missing:
            if missing.status == 404:
                continue        # a1 has no q, x or y file at all
            raise
        for line in text.splitlines():
            cell = line.split("\t")[0]
            if not cell.strip() or cell.startswith("german word"):
                continue
            found.update(headwords(cell))
    return found


def goethe_manifest(name):
    """The other transcription: one bare headword a line, `#` a comment, and a
    leading `~` marking a word its own curriculum teaches as grammar."""
    text = fetch(GOETHE_LIST.format(level=name), f"goethe/{name}-manifest.txt")
    found = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        found.update(headwords(line.lstrip("~").strip()))
    return found


def goethe():
    """A1, A2 and B1 as bands 1, 2 and 3. Lowest level a word appears at wins."""
    bands = {}
    for level, name in ((3, "b1"), (2, "a2"), (1, "a1")):
        found = goethe_tsv(name) | goethe_manifest(name)
        for word in found:
            if acceptable(word, "german"):
                bands[word] = level
    if not bands:
        raise Missing(GOETHE_TSV.format(level="a1", letter="a"), "goethe/a1-a.tsv")
    return bands


# MARK: French — FLELex, at the levels of the Beacco référentiels

def flelex():
    """A1, A2 and B1 as bands 1, 2 and 3, taking a lemma at its lowest level."""
    text = fetch(FLELEX, "FleLex_TT_Beacco.tsv")
    levels = {"A1": 1, "A2": 2, "B1": 3}
    bands = {}
    rows = text.splitlines()
    header = rows[0].split("\t")
    word_at, level_at = header.index("word"), header.index("level")
    for line in rows[1:]:
        cell = line.split("\t")
        if len(cell) <= level_at:
            continue
        level = levels.get(cell[level_at])
        word = cell[word_at].strip().lower()
        if level is None or not acceptable(word, "french"):
            continue
        bands[word] = min(level, bands.get(word, level))
    if not bands:
        raise Missing(FLELEX, "FleLex_TT_Beacco.tsv")
    return bands


# MARK: Bands 4-6 — frequency, with the names taken out

def dictionary(language):
    """Words of the language that are not names. See the module docstring."""
    if language == "german":
        text = fetch(DE_WORDS, "german-wordlist-words.txt")
        return {line.strip().lower() for line in text.splitlines() if line.strip()}
    text = fetch(FR_DIC, "fr.dic")
    known = set()
    for line in text.splitlines()[1:]:
        word = line.strip().split("/")[0]
        # Only the lower-case entries: in fr.dic a proper noun is capitalised.
        if word and word[:1].islower():
            known.add(word.lower())
    return known


def given_names():
    """A name list is the backstop the dictionaries need. Both of them let some
    names through — `Leslie` and `Michel` are in the German word list, `blair`
    and `madison` are lower-case entries in fr.dic — and a name seeded into a
    generated sentence is the one failure here a learner would actually see.

    It costs a handful of real words that are also people: `Faust`, `Mark`,
    `Ton`. That is close to free, because the tail is taken to a fixed size and
    simply reaches one word further down the frequency list for each one lost —
    and this list is only ever seasoning above B1, where one word is one word."""
    text = fetch(NAMES, "first-names.txt", encoding="utf-8-sig")
    return {line.strip().lower() for line in text.splitlines() if line.strip()}


def ranked(code):
    """Word to rank, best rank kept, out of one of hermitdave's lists."""
    order = {}
    text = fetch(FREQ.format(code), f"{code}_50k.txt")
    for rank, line in enumerate(text.splitlines(), start=1):
        word = line.split(" ")[0].strip().lower()
        order.setdefault(word, rank)
    return order


def tail(language, code, banded):
    """Rank buckets over what survives the dictionary and the reduction."""
    known = dictionary(language)
    names = given_names()
    english = ranked("en")
    text = fetch(FREQ.format(code), f"{code}_50k.txt")
    held = set(banded)
    families = set()
    for word in banded:
        families |= family(word, language)
    wanted = iter(TAIL_BANDS)
    level, room = next(wanted)
    bands = {}
    blocked = BLOCKED.get(language, set())
    dropped = {"unknown": 0, "name": 0, "english": 0, "noise": 0,
               "redundant": 0, "banded": 0, "blocked": 0}
    for rank, line in enumerate(text.splitlines(), start=1):
        word = line.split(" ")[0].strip().lower()
        # A syllabus is allowed its two-letter words; at two letters a subtitle
        # corpus is mostly `ok`, `hi` and the wreckage of an elision.
        if not WORD.match(word) or len(word) < MINIMUM:
            continue
        if word in held:
            dropped["banded"] += 1
            continue
        if is_noise(word, language):
            dropped["noise"] += 1
            continue
        if word in blocked:
            dropped["blocked"] += 1
            continue
        if word not in known:
            dropped["unknown"] += 1
            continue
        abroad = english.get(word)
        if abroad is not None and abroad * IMPORTED < rank:
            dropped["english"] += 1
            continue
        if word in names:
            dropped["name"] += 1
            continue
        kin = family(word, language)
        if kin & families:
            dropped["redundant"] += 1
            continue
        bands[word] = level
        held.add(word)
        families |= kin
        room -= 1
        if room == 0:
            try:
                level, room = next(wanted)
            except StopIteration:
                break
    print(f"  tail: kept {len(bands)}; dropped "
          + ", ".join(f"{v} {k}" for k, v in dropped.items()))
    return bands


# MARK: The two European languages

def european(language, code, official, meta):
    bands = official()
    per = {}
    for level in bands.values():
        per[level] = per.get(level, 0) + 1
    print(f"  official: " + ", ".join(f"{k}:{per[k]}" for k in sorted(per)))
    bands.update(tail(language, code, bands))
    write(language, meta, bands)


GERMAN_META = {
    "source": "Goethe-Institut Wortlisten for Goethe-Zertifikat A1 (Start "
              "Deutsch 1), A2 and B1 (DTZ) as bands 1-3; OpenSubtitles 2018 "
              "frequency (Lison & Tiedemann) rank buckets as bands 4-6",
    "copyright": "Bands 1-3 (c) Goethe-Institut e.V., who publish the "
                 "Wortlisten; the mirrors below are transcriptions of those "
                 "PDFs and are not themselves licensed by the Institut.",
    "via": "Bands 1-3: github.com/ilkermeliksitki/goethe-institute-wordlist "
           "and github.com/VitalyVorobyev/deutsch-textbook, unioned because "
           "each transcription omits words the other has. "
           "Bands 4-6: github.com/hermitdave/FrequencyWords (MIT). Filtered "
           "against github.com/enz/german-wordlist (CC0-1.0) and "
           "github.com/smashew/NameDatabases (Unlicense).",
    "bands": "1-3 are A1, A2 and B1 as the Institut grades them, a word taken "
             "at the lowest level it appears. 4-6 are rank buckets of 800 over "
             "the frequency tail, which no official list covers, with "
             "everything already in bands 1-3 removed.",
    "filtered": "Bands 4-6 only. A tail word must appear in a German Scrabble "
                "word list, which excludes names, toponyms and abbreviations "
                "by its own rules — the frequency list is lower-cased, so "
                "`alan` and `peter` are otherwise indistinguishable from "
                "vocabulary — and must not be a known given name, since that "
                "word list has leaks, nor rank five times better in English "
                "subtitles than in German ones, which is a line nobody "
                "translated. Interjections, words shorter than three letters, "
                "words holding a hyphen or a space (the "
                "Lexicon splits on non-letters and could never match them) and "
                "words the Lexicon's own suffix reduction already lands on a "
                "word held here are dropped too.",
}

FRENCH_META = {
    "source": "FLELex-Beacco (Pintard & François 2020), which carries the "
              "expert levels of the Beacco et al. référentiels — Niveau "
              "A1/A2/B1 pour le français, Didier/CIEP — as bands 1-3; "
              "OpenSubtitles 2018 frequency (Lison & Tiedemann) rank buckets "
              "as bands 4-6",
    "copyright": "Bands 1-3 (c) CENTAL, Université catholique de Louvain, "
                 "licensed CC BY-NC-SA 4.0; the levels within it are those of "
                 "the référentiels, (c) their authors and Didier.",
    "via": "Bands 1-3: cental.uclouvain.be/cefrlex/flelex, mirrored at "
           "github.com/nathanschulz/french-vocab-tool data/FleLex_TT_Beacco.tsv. "
           "Bands 4-6: github.com/hermitdave/FrequencyWords (MIT). Filtered "
           "against the Hunspell fr.dic in github.com/LibreOffice/dictionaries "
           "(Dicollecte, MPL 2.0) and github.com/smashew/NameDatabases "
           "(Unlicense).",
    "bands": "1-3 are A1, A2 and B1 as the référentiels grade them, a lemma "
             "taken at the lowest level it appears. 4-6 are rank buckets of "
             "800 over the frequency tail, which no official list covers, with "
             "everything already in bands 1-3 removed.",
    "filtered": "Bands 4-6 only. A tail word must be a lower-case entry of the "
                "French Hunspell dictionary: proper nouns are capitalised "
                "there, so this drops most of the names the lower-cased "
                "frequency list hides, and it leaves lemmas rather than "
                "inflected forms, which is what the Lexicon's reduction aims "
                "at. A known given name is dropped as well, since fr.dic still "
                "carries a few in lower case, and so is a word ranking five "
                "times better in English subtitles than in French ones, which "
                "is a line nobody translated. Interjections, words shorter "
                "than three letters, words holding a "
                "hyphen or a space (the Lexicon splits on non-letters and "
                "could never match them) and words the reduction already lands "
                "on a word held here are dropped too.",
}


if __name__ == "__main__":
    only = sys.argv[1:] or ["mandarin", "german", "french"]
    failed = False
    for name, build in (("mandarin", mandarin),
                        ("german", lambda: european("german", "de", goethe,
                                                    GERMAN_META)),
                        ("french", lambda: european("french", "fr", flelex,
                                                    FRENCH_META))):
        if name not in only:
            continue
        print(name)
        try:
            build()
        except Missing as missing:
            missing.explain()
            failed = True
    sys.exit(1 if failed else 0)
