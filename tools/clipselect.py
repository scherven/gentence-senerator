"""Choosing which recordings a learner should hear.

Common Voice is mostly read Wikipedia, so taking rows in file order gives
taxonomy and place names. This picks by two things instead: how hard the
sentence is, which becomes its level, and how much it sounds like speech.

Levels are derived, never passed in. Mandarin uses the real HSK 3.0
character list; German and French fall back to corpus token frequency,
which is a much weaker proxy.

Corpus frequency cannot be used for Mandarin here: Common Voice zh-CN is
mostly read Wikipedia, where 属 (taxonomic genus) is the 14th most common
character and 喝 (drink) is the 2207th. It ranks learner difficulty almost
backwards.
"""
import collections, csv, json, re, sys
from pathlib import Path

HSK = json.loads((Path(__file__).resolve().parent / "hsk30-characters.json")
                 .read_text(encoding="utf-8"))["levels"]

csv.field_size_limit(10 ** 7)

# HSK 3.0 cumulative character counts, and CEFR bands for the alphabetic
# languages, as frequency-rank cut-offs.
BANDS = {
    "mandarin": [(300, 1), (600, 2), (900, 3), (1200, 4), (1500, 5), (1800, 6), (3000, 7)],
    "german":   [(750, 1), (1500, 2), (3000, 3), (5000, 4), (8000, 5), (14000, 6)],
    "french":   [(750, 1), (1500, 2), (3000, 3), (5000, 4), (8000, 5), (14000, 6)],
}

HANZI = re.compile(r"[一-鿿]")
LATIN_DIGIT = re.compile(r"[0-9A-Za-z０-９]")
CJK_NUMS = set("零一二三四五六七八九十百千万亿两")

# What an encyclopedia says and a person does not.
ENCYCLOPEDIC = {
    "mandarin": re.compile(
        r"[属科目纲界]的|位于|是一[个种座名]|年间|王朝|清朝|明朝|光绪|出生于"
        r"|为[^，]{0,6}的一个|公里|人口|分布于|该[种属]|司职|效力|国旗|所设计"
        r"|大会代表|版本控制|主要[城河]|管理。|等[十百]|[县郡镇寺]"),
    "german": re.compile(r"\bist eine? (Gemeinde|Stadt|Art|Gattung)\b|\bliegt (im|in der)\b"
                         r"|\bEinwohner\b|\bwurde .{0,20}geboren\b|\bLandkreis\b"),
    "french": re.compile(r"\best une? (commune|espèce|genre|ville)\b|\bsitué[e]? (dans|en)\b"
                         r"|\bhabitants\b|\bné en \d|\bdépartement\b"),
}

# What speech has and an encyclopedia does not.
PERSON = {"mandarin": re.compile(r"[我你咱]"),
          "german": re.compile(r"\b(ich|du|wir|mich|dich|mir|dir|unser)\b", re.I),
          "french": re.compile(r"\b(je|tu|nous|moi|toi|mon|ma|ton|ta|notre)\b", re.I)}
PARTICLE = {"mandarin": re.compile(r"[吗呢吧啊][。？！]?$"),
            "german": re.compile(r"[?!]$"), "french": re.compile(r"[?!]$")}
EVERYDAY = {
    "mandarin": re.compile(r"想|要|会|能|喜欢|觉得|知道|说|看|听|吃|喝|去|来|回|买|做|给"
                           r"|等|忙|累|开心|高兴|谢谢|对不起|没有|可以|应该|希望"),
    "german": re.compile(r"\b(gehen|machen|sagen|sehen|essen|trinken|kaufen|denken|glauben"
                         r"|möchte|will|kann|muss|danke|bitte|heute|morgen)\b", re.I),
    "french": re.compile(r"\b(aller|faire|dire|voir|manger|boire|acheter|penser|croire"
                         r"|veux|peux|dois|merci|demain|aujourd)\b", re.I),
}


def tokens(text, language):
    if language == "mandarin":
        return HANZI.findall(text)
    return re.findall(r"[^\W\d_]+", text.lower(), re.UNICODE)


def frequency(rows, language):
    """Rank every token in the corpus. Common is easy; rare is not."""
    counts = collections.Counter()
    for _, text, _ in rows:
        counts.update(tokens(text, language))
    return {t: i for i, (t, _) in enumerate(counts.most_common())}


def level_of(text, language, rank):
    """The level of the hardest token, or None when something in the sentence
    is off the list entirely — which is how the place names and the taxonomy
    get dropped, since 蕨 and 郡 are in no HSK band at all."""
    ts = tokens(text, language)
    if not ts:
        return None
    if language == "mandarin":
        levels = [HSK.get(c) for c in ts]
        return None if any(lv is None for lv in levels) else max(levels)
    hardest = max(rank.get(t, 10 ** 9) for t in ts)
    for cut, level in BANDS[language]:
        if hardest <= cut:
            return level
    return None


def usable(text, seconds, language, min_seconds, max_seconds, min_chars, max_chars):
    if not (min_seconds <= seconds <= max_seconds):
        return False
    if not (min_chars <= len(text) <= max_chars):
        return False
    if language == "mandarin" and LATIN_DIGIT.search(text):
        return False
    if ENCYCLOPEDIC[language].search(text):
        return False
    ts = tokens(text, language)
    if not ts:
        return False
    # Common Voice carries bare digit recordings; they teach nothing.
    if language == "mandarin" and all(t in CJK_NUMS for t in ts):
        return False
    return True


def speechiness(text, language):
    """Higher is more like something a person would say out loud."""
    score = 0
    if PERSON[language].search(text):
        score += 3
    if PARTICLE[language].search(text):
        score += 2
    if EVERYDAY[language].search(text):
        score += 2
    # Long sentences are read, not spoken.
    score -= len(tokens(text, language)) / 12.0
    return score


def choose(rows, language, count, *, min_seconds=1.2, max_seconds=8.0,
           min_chars=5, max_chars=20, report=print):
    """-> [(path, text, seconds, level)], spread evenly over the levels the
    corpus can actually fill, best-sounding first within each."""
    rank = frequency(rows, language)
    best = {}
    for path, text, seconds in rows:
        if not usable(text, seconds, language, min_seconds, max_seconds, min_chars, max_chars):
            continue
        level = level_of(text, language, rank)
        if level is None:
            continue
        # One recording per sentence; keep the first, they are all validated.
        best.setdefault(text, (path, text, seconds, level))

    by_level = collections.defaultdict(list)
    for entry in best.values():
        by_level[entry[3]].append(entry)
    for level in by_level:
        by_level[level].sort(key=lambda e: -speechiness(e[1], language))

    levels = sorted(by_level)
    if not levels:
        return []
    report(f"  candidates per level: " +
           ", ".join(f"{lv}:{len(by_level[lv])}" for lv in levels))

    # Round-robin so a thin level does not starve and a fat one does not swamp.
    picked, cursor = [], collections.defaultdict(int)
    while len(picked) < count:
        progressed = False
        for level in levels:
            if len(picked) >= count:
                break
            i = cursor[level]
            if i < len(by_level[level]):
                picked.append(by_level[level][i])
                cursor[level] += 1
                progressed = True
        if not progressed:
            break
    return picked
