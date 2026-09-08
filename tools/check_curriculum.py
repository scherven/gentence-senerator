#!/usr/bin/env python3
"""Validate the bundled curriculum against the language packs.

Every check derives its expectations from the Swift source rather than a copy
kept here, so the two cannot drift. Run it after editing either.

    python3 tools/check_curriculum.py        # exits 1 on any error
"""
import json, re, sys, pathlib

SRC = pathlib.Path(__file__).resolve().parent.parent / 'gentence-senerator/gentence-senerator'
USES = {'spoken', 'written', 'both'}
FIELDS = {'id', 'name', 'level', 'kind', 'use', 'formulaic', 'instruction', 'examples'}

errors, notes = [], []


def packs():
    """{language: (allowed kind raw values, level ceiling, swift-literal points)}"""
    raw = dict(re.findall(r'case\s+(\w+)\s*=\s*"([^"]+)"',
                          (SRC / 'Core/Atom.swift').read_text()))
    text = (SRC / 'Services/LanguagePacks.swift').read_text()
    universal = re.findall(r'\.(\w+)', re.search(
        r'private static let universal:[^=]*=\s*\[(.*?)\]', text, re.S).group(1))

    marks = [(m.group(1), m.start()) for m in
             re.finditer(r'static let (\w+) = LanguagePack\(', text)]
    out = {}
    for i, (name, start) in enumerate(marks):
        body = text[start:marks[i + 1][1] if i + 1 < len(marks) else len(text)]
        names = set(universal) | set(re.findall(r'\.(\w+)', re.search(
            r'kinds:\s*universal\s*\+\s*\[(.*?)\]', body, re.S).group(1)))
        points = [(pid, raw.get(k, k)) for pid, k in
                  re.findall(r'GrammarPoint\(id:\s*"([^"]+)".*?kind:\s*\.(\w+)', body, re.S)]
        out[name] = ({raw[n] for n in names if n in raw},
                     9 if name == 'mandarin' else 6, points)
    return out


def check(lang, allowed, ceiling, swift_points):
    for pid, kind in swift_points:
        if kind not in allowed:
            errors.append(f'{lang}: LanguagePacks.swift point {pid!r} uses kind '
                          f'{kind!r}, which its pack does not allow — unreachable')

    path = SRC / f'Curriculum/grammar-{lang}.json'
    if not path.exists():
        notes.append(f'{lang}: no curriculum file yet')
        return set()

    points = json.loads(path.read_text())
    if not isinstance(points, list):
        errors.append(f'{lang}: expected a flat array')
        return set()

    seen, levels = set(), {}
    for p in points:
        pid = p.get('id', '?')
        if set(p) != FIELDS:
            errors.append(f'{lang}/{pid}: fields {sorted(set(p) ^ FIELDS)} wrong')
            continue
        if pid in seen:
            errors.append(f'{lang}/{pid}: duplicate id')
        seen.add(pid)
        if p['kind'] not in allowed:
            errors.append(f'{lang}/{pid}: kind {p["kind"]!r} not allowed in this pack')
        if not isinstance(p['level'], int) or not 1 <= p['level'] <= ceiling:
            errors.append(f'{lang}/{pid}: level {p["level"]!r} outside 1-{ceiling}')
        else:
            levels[p['level']] = levels.get(p['level'], 0) + 1
        if p['use'] not in USES:
            errors.append(f'{lang}/{pid}: use {p["use"]!r} not one of {sorted(USES)}')
        if not isinstance(p['formulaic'], bool):
            errors.append(f'{lang}/{pid}: formulaic is not a bool')
        if not p['examples']:
            errors.append(f'{lang}/{pid}: no examples')
        if not p['instruction'].strip():
            errors.append(f'{lang}/{pid}: empty instruction')

    # A gap means pickStretch has nothing to offer a learner sitting at it.
    for n in range(1, ceiling + 1):
        if not levels.get(n):
            errors.append(f'{lang}: no points at level {n}')

    # Points must carry forward: an id that changes loses its scheduling history.
    dropped = {pid for pid, _ in swift_points} - seen
    if dropped:
        errors.append(f'{lang}: ids in LanguagePacks.swift missing from the '
                      f'curriculum — scheduling history would be lost: {sorted(dropped)}')

    unused = sorted(allowed - {p['kind'] for p in points})
    if unused:
        notes.append(f'{lang}: {len(points)} points, levels '
                     f'{dict(sorted(levels.items()))}; kinds never reached for: '
                     f'{", ".join(unused)}')
    else:
        notes.append(f'{lang}: {len(points)} points, levels {dict(sorted(levels.items()))}')
    return seen


for lang, (allowed, ceiling, swift_points) in sorted(packs().items()):
    check(lang, allowed, ceiling, swift_points)

for n in notes:
    print(f'  {n}')
if errors:
    print(f'\n{len(errors)} error(s):', file=sys.stderr)
    for e in errors:
        print(f'  {e}', file=sys.stderr)
    sys.exit(1)
print('\nok')
