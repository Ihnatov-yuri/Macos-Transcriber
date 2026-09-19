#!/usr/bin/env python3
"""Defect counts for a transcript slice: stored transcript (before) vs a fresh run (after)."""
import re, sys

srt_path, start, dur, after_path, elapsed = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4], sys.argv[5]

def srt_window(path, t0, t1, span=None):
    """Entries whose start falls in the window. NOTE: an entry can run well
    past t1 (stored entries span 28-56 s), so the 'before' text may include
    speech the slice does not contain — `span` collects the real coverage so
    the report can say so."""
    try:
        blocks = open(path, encoding="utf-8").read().split("\n\n")
    except FileNotFoundError:
        return None
    out = []
    for b in blocks:
        lines = [l for l in b.strip().split("\n") if l]
        if len(lines) < 3 or "-->" not in lines[1]:
            continue
        h, m, s = lines[1].split(" --> ")[0].replace(",", ".").split(":")
        t = int(h) * 3600 + int(m) * 60 + float(s)
        if t0 <= t < t1:
            out.append(re.sub(r"^[^:]{1,30}:\s", "", " ".join(lines[2:])))
            if span is not None:
                e = lines[1].split(" --> ")[1].replace(",", ".").split(":")
                span.append(int(e[0]) * 3600 + int(e[1]) * 60 + float(e[2]))
    return out

SIGN_OFFS = ["дякую за перегляд", "дякуємо за перегляд", "thanks for watching", "thank you for watching",
             "amara.org", "продовження слідує", "bedankt voor het kijken"]
STOCK_ONLY = re.compile(r"^\W*(дякую|дякуємо|угу|ага|thank you|thanks|bye|you|okay)\W*$", re.I)

def words(t):
    return re.findall(r"[^\W\d_]+(?:['’ʼ-][^\W\d_]+)*", t.lower())

def metrics(lines):
    text = " ".join(lines)
    w = words(text)
    seam = 0
    for a, b in zip(lines, lines[1:]):
        wa, wb = words(a), words(b)
        for k in (3, 2, 1):
            if len(wa) >= k and len(wb) >= k and wa[-k:] == wb[:k] and (k > 1 or len(wa[-1]) >= 4):
                seam += 1
                break
    runs = sum(1 for i in range(len(w) - 3) if w[i] == w[i + 1] == w[i + 2] == w[i + 3])
    return {
        "words": len(w),
        "lines": len(lines),
        "subtitle sign-offs": sum(text.lower().count(s) for s in SIGN_OFFS),
        "stock-line-only lines": sum(1 for l in lines if STOCK_ONLY.match(l)),
        "detached hyphen/colon (' -x', ' :0')": len(re.findall(r"\s[-:][^\W_]", text)),
        "seam repeats between lines": seam,
        "4x word loops": runs,
        "mid-sentence capitals after comma": len(re.findall(r",\s[А-ЯІЇЄҐ][а-яіїєґ]{2,}", text)),
        "Latin-script words": sum(1 for x in w if re.match(r"^[a-z][a-z'’-]*$", x)),
        "non-Ukrainian Cyrillic letters (ыэъё)": len(re.findall(r"[ыэъё]", text.lower())),
    }

span = []
before = srt_window(srt_path, start, start + dur, span)
after = [l.strip() for l in open(after_path, encoding="utf-8") if l.strip()]
ma = metrics(after)
mb = metrics(before) if before else None
print(f"\n{'metric':44} {'before':>8} {'after':>8}")
for k, v in ma.items():
    print(f"{k:44} {(mb[k] if mb else '-'):>8} {v:>8}")
print(f"{'run time (s)':44} {'-':>8} {elapsed:>8}")

if before:
    # Order-INSENSITIVE retention. A sequence diff reports reordering as
    # loss: split-track segments interleave differently between runs, which
    # made a slice with all its content look 20% shorter.
    from collections import Counter
    cb, ca = Counter(words(" ".join(before))), Counter(words(" ".join(after)))
    kept = sum((cb & ca).values())
    print(f"\ncontent retention: {kept}/{sum(cb.values())} of the stored slice's words "
          f"are still present ({100.0 * kept / max(1, sum(cb.values())):.1f}%)")
    missing = [w for w, n in (cb - ca).most_common() if len(w) > 3][:12]
    if missing:
        print("words only in the stored transcript:", ", ".join(missing))
    overrun = max(span) - (start + dur) if span else 0
    if overrun > 1:
        print(f"note: the stored slice runs {overrun:.0f}s past the audio slice "
              f"(last entry ends at {max(span):.0f}s) — that much 'missing' text was never transcribed here")
if not before:
    print("(no stored .srt for this recording — 'before' unavailable)")
