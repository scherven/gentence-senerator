#!/usr/bin/env python3
"""Pull the dialogues out of split ChinesePod lesson videos.

    python3 tools/chinesepod_dialogues.py ~/Downloads/chinesepod

Per lesson video ("NN - LLLL Title.mov"):
  - slides headed "Dialogue" / "Dialogue Part N" are found by OCR on keyframes
  - the dialogue audio is the stretch between an opening chime and the next
    chime, cut at the digital-silence splice when there is one
  - each clip is matched to the Dialogue slide on screen while it plays; every
    distinct slide with that heading is OCR'd, so dialogues spanning several
    slides come out whole

Writes to <out> (default <src>/dialogues):
    <name>.m4a    Apple Lossless, sample-exact
    <name>.mp3    320 kbps
    <name>.txt    speaker <tab> Chinese <tab> English, one line per row
    slides/       the slides the text was read from
    all.tsv       every line of every dialogue
    log.txt       what was found per lesson

Clips with no Dialogue slide on screen are ignored. Cached per lesson under
<out>/.cache; Ctrl-C and rerun resumes. Needs ffmpeg and tesseract (chi_sim).
"""

import argparse, difflib, glob, json, os, re, signal, struct, subprocess, sys, tempfile, threading, wave, zlib
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from tqdm import tqdm

HERE = os.path.dirname(os.path.abspath(__file__))
CHIME = os.path.join(HERE, "chinesepod_chime.wav")
ENV = dict(os.environ, OMP_THREAD_LIMIT="1")

SR, DSR = 48000, 16000   # cut rate, detection rate
CHIME_LEN = 3.58         # onset to the end of the chime's ring
CHIME_MIN = 0.4          # short-template match that counts as a chime
OPEN_MIN = 0.8          # full-template match: chime rang out, so a clip follows
MAX_CLIP = 420.0

HW, HH = 718, 173        # heading crop (top-left 42% x 18%, half scale)
TW, TH = 214, 120        # change-detection thumbnail
HEAD_RE = re.compile(r"Dia\s*log\w*(?:\s*Part\s*([0-9lI|]+))?", re.I)
CJK = re.compile(r"[㐀-鿿]")

STOPPING = False


def _stop(signum, frame):
    global STOPPING
    if STOPPING:
        raise KeyboardInterrupt
    STOPPING = True
    tqdm.write("stopping after this lesson; progress is saved (Ctrl-C again to abort)")


signal.signal(signal.SIGINT, _stop)


# ---------------------------------------------------------------- helpers

def run(cmd, **kw):
    # own session: a terminal Ctrl-C must not kill ffmpeg/tesseract mid-stage
    return subprocess.run(cmd, capture_output=True, start_new_session=True, env=ENV, **kw)


def save_json(path, obj):
    with open(path + ".part", "w") as f:
        json.dump(obj, f, ensure_ascii=False, indent=1)
    os.replace(path + ".part", path)


def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def probe(path):
    r = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
             "stream=width,height:format=duration", "-of", "json", path], text=True)
    j = json.loads(r.stdout)
    return float(j["format"]["duration"]), j["streams"][0]["width"], j["streams"][0]["height"]


def tesseract(img, lang, psm, *extra):
    hdr = b"P%d %d %d 255\n" % (5 if img.ndim == 2 else 6, img.shape[1], img.shape[0])
    r = run(["tesseract", "stdin", "stdout", "-l", lang, "--psm", str(psm), *extra],
            input=hdr + np.ascontiguousarray(img, np.uint8).tobytes())
    return r.stdout.decode("utf-8", "replace").strip()


def frame(path, t, w, h):
    r = run(["ffmpeg", "-v", "error", "-ss", "%.3f" % t, "-i", path, "-frames:v", "1",
             "-f", "rawvideo", "-pix_fmt", "rgb24", "-"])
    return np.frombuffer(r.stdout, np.uint8).reshape(h, w, 3)


def write_png(img, dst):
    with open(dst + ".part", "wb") as f:
        f.write(png(img))
    os.replace(dst + ".part", dst)


# ---------------------------------------------------------------- slides

def heading_of(crop):
    m = HEAD_RE.search(tesseract(crop, "eng", 6))
    if not m:
        return None
    return "Dialogue Part %s" % re.sub(r"[lI|]", "1", m.group(1)) if m.group(1) else "Dialogue"


def scan(path, dur):
    """Every other keyframe (~2 s): heading label, and clusters of distinct Dialogue slides."""
    vf = ("select='not(mod(n\\,2))',showinfo,split[a][b];"
          "[a]crop=iw*0.42:ih*0.18:0:0,scale=%d:%d[h];[b]scale=%d:%d,pad=%d:%d[t];"
          "[h][t]vstack,format=gray" % (HW, HH, TW, TH, HW, TH))
    p = subprocess.Popen(["ffmpeg", "-v", "info", "-hwaccel", "videotoolbox", "-skip_frame", "nokey",
                          "-i", path, "-an", "-vf", vf, "-fps_mode", "vfr", "-f", "rawvideo", "-"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    ts = []

    def read_times():
        for line in p.stderr:
            m = re.search(rb"\bn:\s*\d+ .*?pts_time:([0-9.]+)", line)
            if m:
                ts.append(float(m.group(1)))

    th = threading.Thread(target=read_times, daemon=True)
    th.start()
    size = HW * (HH + TH)
    rows, clusters, prev, label = [], [], None, None
    bar = tqdm(total=int(dur), unit="s", desc="  scan", leave=False, position=1)
    while True:
        buf = p.stdout.read(size)
        if len(buf) < size:
            break
        while len(ts) <= len(rows) and th.is_alive():
            th.join(0.005)
        t = ts[len(rows)] if len(rows) < len(ts) else rows[-1][0] + 1.9
        f = np.frombuffer(buf, np.uint8).reshape(HH + TH, HW)
        tn = f[HH:, :TW].astype(np.float32)
        if prev is None or (np.abs(tn - prev) > 25).mean() > 0.002:
            label = heading_of(f[:HH])
        prev = tn
        rows.append((round(t, 3), label))
        # skip frames with the player's dark overlay bars
        if label and tn[:4].mean() > 150 and tn[-8:].mean() > 150:
            for c in clusters:
                if c["heading"] == label and (np.abs(tn - c["thumb"]) > 25).mean() < 0.004:
                    c["times"].append(round(t, 3))
                    break
            else:
                clusters.append({"heading": label, "times": [round(t, 3)], "thumb": tn})
        bar.update(max(0, int(t) - bar.n))
    p.wait()
    bar.close()
    if not rows or rows[-1][0] < dur - 15:
        raise RuntimeError("keyframe scan ended early at %.0fs of %.0fs" % (rows[-1][0] if rows else 0, dur))
    for c in clusters:
        del c["thumb"]
    return {"rows": rows, "clusters": clusters}


def disc(mask, img, x0, y0, x1, y1):
    """Speaker badge: a filled circle just right of the card's bar. Returns (right edge, letter) or None."""
    sub = mask[y0:y1, x0:x1]
    cols = sub.sum(0)
    xs = np.where(cols >= 10)[0]
    if not len(xs):
        return None
    a = xs[0]
    b = a
    while b < len(cols) and cols[b] >= 3:
        b += 1
    w = b - a
    if not 35 <= w <= 130:
        return None
    ys = np.where(sub[:, a:b].any(1))[0]
    top = ys[0]
    bot = top
    while bot < len(sub) and sub[bot, a:b].any():
        bot += 1
    hgt = bot - top
    if not 0.8 <= hgt / w <= 1.25:
        return None
    box = sub[top:bot, a:b]
    k = max(2, w // 5)
    corners = np.mean([box[:k, :k].mean(), box[:k, -k:].mean(), box[-k:, :k].mean(), box[-k:, -k:].mean()])
    if box.mean() < 0.55 or corners > 0.3:
        return None
    rgb = img[y0 + top:y0 + bot, x0 + a:x0 + b]
    letter = np.where(rgb.min(2) > 180, 0, 255).astype(np.uint8)
    letter[~box] = 255
    letter = np.pad(letter, 20, constant_values=255)
    s = tesseract(letter, "eng", 10, "-c", "tessedit_char_whitelist=ABCDEFGHIJKLMNOPQRSTUVWXYZ")
    return x0 + b, (s[:1] if len(s) == 1 else None)


def bands(ink, min_h=8, gap=3):
    ys = np.where(ink >= 2)[0]
    out = []
    if not len(ys):
        return out
    start = prev = ys[0]
    for y in ys[1:]:
        if y - prev > gap + 1:
            if prev - start + 1 >= min_h:
                out.append((start, prev + 1))
            start = y
        prev = y
    if prev - start + 1 >= min_h:
        out.append((start, prev + 1))
    return out


def is_pinyin(s):
    # pinyin on these slides is red; this only catches uncoloured pinyin with tone marks
    return bool(re.search(r"[āǎēěīǐōǒūǔǖǘǚǜ]", s))


WIDE = "　-〿㐀-鿿＀-￯“”‘’"


def clean_zh(s):
    s = re.sub(r"\s+", " ", s).strip()
    for a, b in ((",", "，"), ("?", "？"), ("!", "！"), (":", "："), (";", "；")):
        s = re.sub(r"(?<=[%s])\s*%s" % (WIDE, re.escape(a)), b, s)
    s = re.sub(r"(?<=[%s]) (?=[%s])" % (WIDE, WIDE), "", s)
    s = re.sub(r"(?<=[%s]) (?=[A-Za-z0-9])|(?<=[A-Za-z0-9]) (?=[%s])" % (WIDE, WIDE), "", s)
    return s


def clean_en(s):
    s = re.sub(r"\s+", " ", s).strip()
    return re.sub(r"(?<![\w'])\|(?![\w'])", "I", s)


VISION_SRC = r"""
import Foundation
import Vision
// usage: vision-ocr <langs> <png>...  ->  JSON array, one string per image
let args = CommandLine.arguments
var out: [String] = []
for path in args.dropFirst(2) {
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.recognitionLanguages = args[1].split(separator: ",").map(String.init)
    req.usesLanguageCorrection = true
    try? VNImageRequestHandler(url: URL(fileURLWithPath: path), options: [:]).perform([req])
    // top to bottom by line, left to right within a line
    var lines: [[VNRecognizedTextObservation]] = []
    for o in (req.results ?? []).sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
        if let last = lines.last?.first, abs(last.boundingBox.midY - o.boundingBox.midY) < last.boundingBox.height / 2 {
            lines[lines.count - 1].append(o)
        } else {
            lines.append([o])
        }
    }
    out.append(lines.map { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        .compactMap { $0.topCandidates(1).first?.string }.joined() }.joined(separator: "\n"))
}
FileHandle.standardOutput.write(try! JSONSerialization.data(withJSONObject: out))
"""
VISION = None


def build_vision(cache):
    """macOS Vision reads Chinese far better than tesseract; tesseract chi_sim is the fallback."""
    global VISION
    exe = os.path.join(cache, "vision-ocr")
    try:
        with open(exe + ".swift") as f:
            fresh = f.read() == VISION_SRC and os.path.exists(exe)
    except OSError:
        fresh = False
    if not fresh:
        with open(exe + ".swift", "w") as f:
            f.write(VISION_SRC)
        # Apple's python3 shim sets CPATH=/usr/local/include, which breaks the Swift module build
        env = {k: v for k, v in ENV.items() if k not in ("CPATH", "LIBRARY_PATH", "SDKROOT")}
        r = subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-O", exe + ".swift", "-o", exe],
                           capture_output=True, start_new_session=True, env=env)
        if r.returncode:
            tqdm.write("Vision OCR unavailable (%s); using tesseract chi_sim" % r.stderr.decode()[-200:].strip())
            return
    VISION = exe


def png(img):
    h, w = img.shape[:2]
    raw = np.hstack([np.zeros((h, 1), np.uint8), img.reshape(h, -1)]).tobytes()

    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2 if img.ndim == 3 else 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6)) + chunk(b"IEND", b""))


def ocr_zh(crops, pool):
    """One Chinese line per crop."""
    got = [""] * len(crops)
    if VISION and crops:
        with tempfile.TemporaryDirectory() as d:
            paths = []
            for i, c in enumerate(crops):
                paths.append(os.path.join(d, "%d.png" % i))
                with open(paths[-1], "wb") as f:
                    f.write(png(c))
            r = run([VISION, "zh-Hans", *paths])
            try:
                got = json.loads(r.stdout)
            except ValueError:
                pass
    missing = [i for i, s in enumerate(got) if not CJK.search(s)]
    for i, s in zip(missing, pool.map(lambda i: tesseract(crops[i], "chi_sim", 7), missing)):
        got[i] = s
    return got


def zones_of(img, x0, y0, x1, y1):
    """Split a region into runs of lines by ink: Chinese is bold black, English
    grey, pinyin red. -> [[kind, [(top, bottom), ...]]] in absolute rows."""
    reg = img[y0:y1, x0:x1].astype(np.int16)
    ink = reg.min(2) < 170
    red = ink & (reg[..., 0] - np.maximum(reg[..., 1], reg[..., 2]) > 60)
    dark = reg.max(2) < 60
    n = ink.sum(1)
    rk = np.where(red.sum(1) > 0.4 * n, 2, np.where(dark.sum(1) > 0.35 * n, 0, 1))   # 0 zh, 1 en, 2 py
    pieces = []
    for a, z in bands(n, gap=2):
        # lines of different colours can sit too close to separate by gaps; split
        # where the per-row colour changes, smoothing over a line's antialiased edges
        ys = np.arange(a, z)
        ys = ys[n[ys] >= 2]
        k = np.array([np.bincount(rk[ys[max(0, i - 3):i + 4]], minlength=3).argmax() for i in range(len(ys))])
        runs = []
        for y, kk in zip(ys, k):
            if runs and runs[-1][0] == kk:
                runs[-1][2] = y + 1
            else:
                runs.append([kk, y, y + 1])
        for r in runs:
            if r[2] - r[1] < 6 and len(runs) > 1:
                continue    # a stub: leave it to its neighbour
            pieces.append(r)
    zones = []
    for kk, a, z in pieces:
        kind = ("zh", "en", "py")[kk]
        if zones and zones[-1][0] == kind and y0 + a - zones[-1][1][-1][1] < 40:
            zones[-1][1].append((y0 + a, y0 + z))
        else:
            zones.append([kind, [(y0 + a, y0 + z)]])
    return zones


def read_groups(img, groups, pool):
    """groups: [(speaker, x0, x1, zones)] -> entries."""
    def crop(x0, x1, a, z):
        return np.pad(img[a:z, x0:x1], ((16, 16), (16, 16), (0, 0)), constant_values=255)

    zh_crops, zh_at, en_jobs = [], [], []
    for gi, (_, x0, x1, zones) in enumerate(groups):
        for zi, (kind, bs) in enumerate(zones):
            if kind == "zh":
                for a, z in bs:
                    zh_crops.append(crop(x0, x1, a, z))
                    zh_at.append((gi, zi))
            elif kind == "en":
                en_jobs.append((gi, zi, crop(x0, x1, bs[0][0], bs[-1][1])))
    text = {}
    for at, s in zip(zh_at, ocr_zh(zh_crops, pool)):
        text[at] = text.get(at, "") + s
    for (gi, zi, _), s in zip(en_jobs, pool.map(lambda j: tesseract(j[2], "eng", 6), en_jobs)):
        text[gi, zi] = s
    entries = []
    for gi, (speaker, _, _, zones) in enumerate(groups):
        lines = []
        for zi, (kind, _) in enumerate(zones):
            s = text.get((gi, zi), "")
            if kind == "zh":
                lines.append(("zh", clean_zh(s)))
            elif kind == "en":
                s = clean_en(s)
                lines.append(("py" if is_pinyin(s) else "en", s))
        entries += entries_from(lines, speaker)
    return entries


def entries_from(lines, speaker=""):
    out, cur = [], None
    for kind, text in lines:
        if not text or kind == "py":
            continue
        if kind == "zh":
            if cur is None or cur["en"]:
                cur = {"speaker": speaker if not out else "", "zh": "", "en": ""}
                out.append(cur)
            cur["zh"] += text
        else:
            if cur is None:
                cur = {"speaker": speaker, "zh": "", "en": ""}
                out.append(cur)
            cur["en"] = (cur["en"] + " " + text).strip()
    for e in out:
        m = re.match(r"^\s*([A-Z])\s*[:：;；]\s*(.*)$", e["zh"])
        if m:
            e["speaker"], e["zh"] = m.group(1), m.group(2)
        elif not e["speaker"] and speaker:
            e["speaker"] = speaker
    return out


def parse_slide(img, pool):
    """Dialogue slide -> entries in reading order (columns left to right, cards top to bottom)."""
    H, W, _ = img.shape
    c = img.astype(np.int16)
    red = (c[..., 0] > 170) & (c[..., 1] < 90) & (c[..., 2] < 90)
    blk = (c.max(2) < 60)
    m = red | blk
    m[:int(H * 0.10)] = False
    m[:, :int(W * 0.02)] = False            # page border
    run_, best = np.zeros(W, np.int32), np.zeros(W, np.int32)
    for y in range(int(H * 0.10), H):
        run_ = np.where(m[y], run_ + 1, 0)
        best = np.maximum(best, run_)
    xs = np.where(best >= 100)[0]
    bars = []
    for x in xs:
        if bars and x - bars[-1][1] <= 3:
            bars[-1][1] = x
        else:
            bars.append([x, x])
    bars = [g for g in bars if g[1] - g[0] <= 40]

    groups = []
    if not bars:  # no cards: split the body into columns on wide vertical gaps
        top, bot, off = int(H * 0.175), int(H * 0.985), int(W * 0.02)
        ink = (c[top:bot, off:int(W * 0.99)].min(2) < 170).sum(0) > 0
        cols, start, gap = [], None, 0
        for x, on in enumerate(ink):
            if on:
                start = x if start is None else start
                gap = 0
            elif start is not None:
                gap += 1
                if gap >= 60:
                    cols.append((start, x - gap + 1))
                    start = None
        if start is not None:
            cols.append((start, len(ink)))
        for a, b in cols:
            groups.append(("", off + a, off + b + 1, zones_of(img, off + a, top, off + b + 1, bot)))
        return read_groups(img, groups, pool)

    for gi, (xa, xb) in enumerate(bars):
        x1 = bars[gi + 1][0] - 12 if gi + 1 < len(bars) else int(W * 0.985)
        ys = np.where(m[:, xa:xb + 1].mean(1) > 0.6)[0]
        cards, s = [], None
        for i, y in enumerate(ys):
            if s is None:
                s = y
            if i + 1 == len(ys) or ys[i + 1] - y > 2:
                if y - s >= 100:
                    cards.append((s, y + 1))
                s = None
        for y0, y1 in cards:
            is_red = red[y0:y1, xa:xb + 1].mean() > blk[y0:y1, xa:xb + 1].mean()
            d = disc(m, img, xb + 8, y0, min(xb + 220, x1), min(y1, y0 + 170))
            tx0 = d[0] + 4 if d else xb + 12
            speaker = (d[1] or ("A" if is_red else "B")) if d else ""
            groups.append((gi, y0, (speaker, tx0, x1, zones_of(img, tx0, y0 + 4, x1, y1 - 4))))
    # cards on a grid (tops aligned across columns) read row by row; staggered ones column by column
    aligned = sum(any(g2 != g and abs(t2 - t) <= 6 for g2, t2, _ in groups) for g, t, _ in groups)
    if len(bars) > 1 and aligned >= 0.7 * len(groups):
        rows, order = [], []
        for g, t, card in sorted(groups, key=lambda c: c[1]):
            if not rows or t - rows[-1] > 6:
                rows.append(t)
            order.append((len(rows), g, card))
        groups = [card for _, _, card in sorted(order, key=lambda c: c[:2])]
    else:
        groups = [card for _, _, card in groups]
    return read_groups(img, groups, pool)


def key(e):
    return re.sub(r"[\W_]", "", e["zh"]) or re.sub(r"\W", "", e["en"].lower())


def merge(entries):
    out = []
    for e in entries:
        k = key(e)
        if k and not any(difflib.SequenceMatcher(None, k, key(o)).ratio() >= 0.8 for o in out):
            out.append(e)
    return out


# ---------------------------------------------------------------- audio

def decode(path, sr):
    r = run(["ffmpeg", "-v", "error", "-i", path, "-vn", "-map", "0:a:0", "-ac", "1", "-ar", str(sr), "-f", "f32le", "-"])
    return np.frombuffer(r.stdout, np.float32)


def load_chime():
    with wave.open(CHIME) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float64)

    def norm(t):
        t = t - t.mean()
        return t / np.linalg.norm(t)
    return norm(x[:int(1.1 * DSR)]), norm(x)


def ncc(x, t, chunk=1 << 22):
    n = len(t)
    L = 1 << int(np.ceil(np.log2(chunk + n)))
    T = np.conj(np.fft.rfft(t, L))
    out = np.zeros(max(len(x) - n + 1, 0))
    for s in range(0, len(out), chunk):
        c = np.fft.irfft(np.fft.rfft(x[s:s + chunk + n - 1], L) * T, L)
        k = min(chunk, len(out) - s)
        out[s:s + k] = c[:k]
    cs = np.cumsum(np.r_[0.0, x.astype(np.float64) ** 2])
    e = cs[n:] - cs[:-n]
    return np.where(e > n * 1e-6, out / np.sqrt(np.maximum(e, 1e-12)), 0.0)


def zero_runs(x):
    z = np.abs(x) < 1e-5
    d = np.diff(np.r_[0, z.astype(np.int8), 0])
    runs = []
    for s, e in zip(np.where(d == 1)[0], np.where(d == -1)[0]):
        if e - s < 24:
            continue
        if runs and s - runs[-1][1] <= 48:
            runs[-1][1] = int(e)
        else:
            runs.append([int(s), int(e)])
    return [r for r in runs if r[1] - r[0] >= 240]


def audio(path):
    short, full = load_chime()
    x16 = decode(path, DSR)
    c = ncc(x16, short)
    onsets = []
    for i in np.where(c > CHIME_MIN)[0]:
        if onsets and i - onsets[-1] < 2 * DSR:
            if c[i] > c[onsets[-1]]:
                onsets[-1] = i
        else:
            onsets.append(i)
    chimes = []
    for i in onsets:
        seg = x16[i:i + len(full)].astype(np.float64)
        seg = seg - seg.mean()
        f = float(np.dot(seg, full[:len(seg)]) / (np.linalg.norm(seg) + 1e-12))
        chimes.append([round(i / DSR, 4), round(float(c[i]), 3), round(f, 3)])
    zeros = zero_runs(decode(path, SR))

    clips = []
    for k, (t, _, f) in enumerate(chimes[:-1]):
        t2 = chimes[k + 1][0]
        after = [z for z in zeros if t + 2.0 <= z[0] / SR <= t + 8.0]
        start = after[0][1] if after else int((t + CHIME_LEN) * SR)
        before = [z for z in zeros if t2 - 1.5 <= z[1] / SR <= t2 + 0.1 and z[0] > start]
        end = before[-1][0] if before else int((t2 - 0.1) * SR)
        clips.append({"start": start, "end": end, "open": f,
                      "ok": f >= OPEN_MIN and 3 * SR < end - start <= MAX_CLIP * SR})
    return {"chimes": chimes, "zeros": zeros, "clips": clips}


def export(path, s, e, dst, title, track):
    meta = ["-metadata", "title=" + title, "-metadata", "album=ChinesePod Dialogues", "-metadata", "track=%d" % track]
    af = "atrim=start_sample=%d:end_sample=%d,asetpts=PTS-STARTPTS" % (s, e)
    for ext, fmt, codec in ((".m4a", "ipod", ["-c:a", "alac", "-sample_fmt", "s32p"]),
                            (".mp3", "mp3", ["-c:a", "libmp3lame", "-b:a", "320k", "-id3v2_version", "3"])):
        if os.path.exists(dst + ext):
            continue
        r = run(["ffmpeg", "-v", "error", "-y", "-i", path, "-vn", "-map", "0:a:0", "-af", af, *codec, *meta,
                 "-f", fmt, dst + ext + ".part"])
        if r.returncode:
            raise RuntimeError(r.stderr.decode()[-500:])
        os.replace(dst + ext + ".part", dst + ext)


# ---------------------------------------------------------------- driver

def process(path, out, track, pool, outer):
    stem = os.path.splitext(os.path.basename(path))[0]
    cache = os.path.join(out, ".cache", stem)
    os.makedirs(cache, exist_ok=True)
    res = load_json(os.path.join(cache, "result.json"))
    if res is not None:
        return res
    dur, w, h = probe(path)
    notes = []

    outer.set_postfix_str("slides")
    sc = load_json(os.path.join(cache, "scan.json"))
    if sc is None:
        sc = scan(path, dur)
        save_json(os.path.join(cache, "scan.json"), sc)
    order = []
    for cl in sorted(sc["clusters"], key=lambda cl: cl["times"][0]):
        if cl["heading"] not in order:
            order.append(cl["heading"])
    if not order:
        res = {"stem": stem, "dialogues": [], "notes": ["no Dialogue slide; skipped"]}
        save_json(os.path.join(cache, "result.json"), res)
        return res

    outer.set_postfix_str("audio")
    au = load_json(os.path.join(cache, "audio.json"))
    if au is None:
        au = audio(path)
        save_json(os.path.join(cache, "audio.json"), au)
    # one dialogue per clip: every Dialogue heading on screen while it plays
    # (parts are pages of one recording); replays are dropped
    ts = np.array([r[0] for r in sc["rows"]])
    labels = [r[1] for r in sc["rows"]]
    plan, covered = [], set()
    for c in au["clips"]:
        if not c["ok"]:
            continue
        sel = [labels[i] for i in np.where((ts >= c["start"] / SR) & (ts <= c["end"] / SR))[0]]
        hs = [l for l in sel if l]
        if not sel or len(hs) < 0.5 * len(sel):
            continue
        parts = [l for l in order if hs.count(l) >= min(2, max(hs.count(x) for x in hs))]
        if set(parts) <= covered:
            continue
        plan.append((parts, c))
        covered |= set(parts)
    plan += [([hd], None) for hd in order if hd not in covered]

    outer.set_postfix_str("text")
    texts = {}
    os.makedirs(os.path.join(out, "slides"), exist_ok=True)
    for hd in order:
        tpath = os.path.join(cache, "text - %s.json" % hd)
        texts[hd] = load_json(tpath)
        if texts[hd] is None:
            texts[hd] = read_heading(path, w, h, [cl for cl in sc["clusters"] if cl["heading"] == hd],
                                     os.path.join(out, "slides", "%s - %s" % (stem, hd)), pool)
            save_json(tpath, texts[hd])

    dialogues = []
    for parts, c in plan:
        nums = [p.replace("Dialogue Part ", "") for p in parts if p.startswith("Dialogue Part ")]
        if len(nums) != len(parts) or nums == [str(i) for i in range(1, len(nums) + 1)]:
            name = stem     # "Dialogue", or every part from 1
        else:
            name = "%s (Part %s)" % (stem, "-".join([nums[0], nums[-1]]) if len(nums) > 1 else nums[0])
        lines = merge([e for p in parts for e in texts[p]])
        if c is None:
            notes.append("%s: no complete chime-bracketed clip; text only" % ", ".join(parts))
        else:
            export(path, c["start"], c["end"], os.path.join(out, name), name, track)
        with open(os.path.join(out, name + ".txt"), "w") as f:
            f.writelines("%s\t%s\t%s\n" % (e["speaker"], e["zh"], e["en"]) for e in lines)
        dialogues.append({"name": name, "parts": parts, "lines": lines,
                          "clip": [c["start"] / SR, c["end"] / SR] if c else None})
    res = {"stem": stem, "dialogues": dialogues, "notes": notes,
           "chimes": au["chimes"], "clips": [[c["start"] / SR, c["end"] / SR, c["open"], c["ok"]] for c in au["clips"]]}
    save_json(os.path.join(cache, "result.json"), res)
    return res


def sharpness(img):
    g = img[::2, ::2].mean(2)
    return float(np.abs(np.diff(g, axis=1)).mean() + np.abs(np.diff(g, axis=0)).mean())


def read_heading(path, w, h, clusters, png_base, pool):
    """OCR every distinct slide under one heading. Each slide is read from the
    sharpest of three frames; slides much blurrier than the best (captured
    mid-transition) are dropped."""
    big = [cl for cl in clusters if len(cl["times"]) >= 2] or clusters
    big = sorted(sorted(big, key=lambda cl: -len(cl["times"]))[:12], key=lambda cl: cl["times"][0])
    shots = []
    for cl in big:
        t = cl["times"]
        cands = sorted({t[len(t) // 4], t[len(t) // 2], t[(3 * len(t)) // 4]})
        imgs = [frame(path, x, w, h) for x in cands]
        s = [sharpness(i) for i in imgs]
        shots.append((max(s), imgs[int(np.argmax(s))]))
    top = max(s for s, _ in shots)
    found = []
    for n, (s, img) in enumerate([x for x in shots if x[0] >= 0.6 * top], 1):
        write_png(img, "%s %d.png" % (png_base, n))
        found += parse_slide(img, pool)
    return merge(found)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("src", help="folder of split lesson videos")
    ap.add_argument("--out", help="default: <src>/dialogues")
    ap.add_argument("--only", nargs="*", help="lesson numbers or name fragments")
    a = ap.parse_args()
    src = os.path.expanduser(a.src)
    out = os.path.expanduser(a.out or os.path.join(src, "dialogues"))
    os.makedirs(out, exist_ok=True)
    if run(["tesseract", "--list-langs"]).stdout.decode().split().count("chi_sim") == 0:
        sys.exit("tesseract has no chi_sim; install chi_sim.traineddata into its tessdata folder")
    os.makedirs(os.path.join(out, ".cache"), exist_ok=True)
    build_vision(os.path.join(out, ".cache"))
    files = sorted(p for p in glob.glob(os.path.join(src, "*.mov")) if re.match(r"\d+ - \d{4} ", os.path.basename(p)))
    if a.only:
        files = [p for p in files if any(o in os.path.basename(p) for o in a.only)]

    results = []
    with ThreadPoolExecutor(os.cpu_count()) as pool:
        outer = tqdm(files, unit="lesson", position=0)
        for track, path in enumerate(outer, 1):
            if STOPPING:
                break
            outer.set_description(os.path.basename(path)[:9])
            try:
                res = process(path, out, track, pool, outer)
            except Exception as e:  # one bad lesson should not stop the batch
                tqdm.write("%s: FAILED: %s" % (os.path.basename(path), e))
                continue
            results.append(res)
            ds = ", ".join("%s %s %d lines" % ("+".join(d["parts"]), "%.1fs" % (d["clip"][1] - d["clip"][0]) if d["clip"] else "no audio",
                                                len(d["lines"])) for d in res["dialogues"])
            tqdm.write("%s: %s%s" % (res["stem"], ds or "-", "".join("\n    " + n for n in res["notes"])))

    done = [load_json(p) for p in sorted(glob.glob(os.path.join(out, ".cache", "*", "result.json")))]
    with open(os.path.join(out, "all.tsv"), "w") as f:
        f.write("dialogue\tline\tspeaker\tchinese\tenglish\n")
        for r in done:
            for d in r["dialogues"]:
                for i, e in enumerate(d["lines"], 1):
                    f.write("%s\t%d\t%s\t%s\t%s\n" % (d["name"], i, e["speaker"], e["zh"], e["en"]))
    with open(os.path.join(out, "log.txt"), "w") as f:
        for r in done:
            f.write("%s\n  chimes %s\n  clips %s\n" % (r["stem"], r.get("chimes"), r.get("clips")))
            for d in r["dialogues"]:
                f.write("  %s: clip %s, %d lines\n" % ("+".join(d["parts"]), d["clip"], len(d["lines"])))
            for n in r["notes"]:
                f.write("  note: %s\n" % n)
    print("done: %d lessons -> %s" % (len(done), out))


if __name__ == "__main__":
    main()
