#!/usr/bin/env python3
"""Score a transcript against a hand-checked reference.

    eval_wer.py <reference.txt> <hypothesis.txt> [--vocab "A, B, C"] [--show]

Both files are plain text. The WER is over CONTENT words: punctuation,
hesitation sounds (um, uh, е, мм) and spoken particles and back-channels
(ну, от, да, типа, угу, ага ...) are left out on both sides. The Ukrainian
engines write speech as spoken while the references are clean, and nobody has
listened to say which particles were really said, so they cannot be scored
as right or wrong (2026-11-11).

They are counted instead, next to the WER:
  fillers N (ref M)   particles and hesitation sounds in the transcript
  repeats N (ref M)   words that say again what was just said: a doubled
                      word ("так так"), or a phrase of 3+ words standing
                      again within four words ("ти ще й залишишся там. Угу.
                      То може ти ще й залишишся там.")
A count that jumps between two builds is the signal; the reference's own
count shows how much of it is ordinary speech.

Prints WER with its substitution/deletion/insertion split, and, with --vocab, how many vocabulary terms that occur in the reference were
written exactly that way in the hypothesis (case-sensitive: "Blitz" for
"Blits" is a miss).
"""
import re, sys

FILLERS = {"um", "uh", "uhm", "hmm", "mm", "mhm", "ah", "eh", "er", "erm", "oh",
           "е", "ем", "еее", "ее", "м", "мм", "ну", "угу", "ага", "а-а", "хм",
           # Ukrainian spoken particles and back-channels
           "от", "ось", "вот", "да", "типа", "типу", "якби", "а", "о", "ой",
           "короче", "коротше", "значить", "блін"}

# Spelled-out English numbers score the same as digits ("twelve" = "12").
NUMBERS = {w: str(i) for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
    "fifteen sixteen seventeen eighteen nineteen twenty".split())}
NUMBERS.update({"thirty": "30", "forty": "40", "fifty": "50", "hundred": "100"})
# "100%" scores the same as "100 percent" / "100 відсотків".
NUMBERS.update({w: "percent" for w in ("відсотків", "відсотки", "відсоток", "відсотка", "процентів")})

def spoken(w):
    """Ukrainian infinitives as spoken score the same as written: "внідрять" = "внідряти",
    "виділятись" = "виділятися"."""
    if len(w) >= 5 and w.endswith("тися"):
        return w[:-4] + "тись"
    if len(w) >= 5 and w.endswith("ти"):
        return w[:-2] + "ть"
    return w

def words(text):
    text = text.lower().replace("’", "'").replace("ʼ", "'").replace("%", " percent ")
    ws = re.findall(r"[^\W_]+(?:'[^\W_]+)*", text)  # hyphens split: "A-B" = "A/B", "man-hours" = "man hours"
    return [spoken(NUMBERS.get(w, w)) for w in ws if w not in FILLERS]

def raw_words(text):
    text = text.lower().replace("’", "'").replace("ʼ", "'")
    return re.findall(r"[^\W_]+(?:'[^\W_]+)*", text)

def filler_count(text):
    return sum(1 for w in raw_words(text) if w in FILLERS)

def repeat_count(text):
    """Words that repeat what was just said (see the module docstring)."""
    w, i, count = raw_words(text), 0, 0
    while i < len(w):
        hit = 0
        for n in range(8, 2, -1):
            if i + 2 * n > len(w): continue
            phrase = w[i:i + n]
            if any(w[j:j + n] == phrase for j in range(i + n, min(i + n + 5, len(w) - n + 1))):
                hit = n; break
        if hit:
            count += hit; i += hit
        elif i + 1 < len(w) and w[i] == w[i + 1]:
            count += 1; i += 1
        else:
            i += 1
    return count

def align(ref, hyp):
    n, m = len(ref), len(hyp)
    d = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1): d[i][0] = i
    for j in range(m + 1): d[0][j] = j
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            d[i][j] = min(d[i-1][j-1] + (ref[i-1] != hyp[j-1]), d[i-1][j] + 1, d[i][j-1] + 1)
    i, j, ops = n, m, []
    while i or j:
        if i and j and d[i][j] == d[i-1][j-1] + (ref[i-1] != hyp[j-1]):
            ops.append(("=" if ref[i-1] == hyp[j-1] else "S", ref[i-1], hyp[j-1])); i, j = i-1, j-1
        elif i and d[i][j] == d[i-1][j] + 1:
            ops.append(("D", ref[i-1], "")); i -= 1
        else:
            ops.append(("I", "", hyp[j-1])); j -= 1
    return ops[::-1]

def score(ref_text, hyp_text):
    ops = align(words(ref_text), words(hyp_text))
    c = {k: sum(1 for o in ops if o[0] == k) for k in "SDI="}
    n = c["S"] + c["D"] + c["="]
    return {"n": n, "S": c["S"], "D": c["D"], "I": c["I"],
            "wer": (c["S"] + c["D"] + c["I"]) / max(n, 1)}, ops

def vocab_hits(ref_text, hyp_text, vocab):
    hit = total = 0
    missed = []
    for term in vocab:
        pat = re.compile(r"(?<![\w])" + re.escape(term) + r"(?![\w])")
        k = len(pat.findall(ref_text))
        if not k: continue
        h = min(k, len(pat.findall(hyp_text)))
        hit += h; total += k
        if h < k: missed.append(f"{term} {h}/{k}")
    return hit, total, missed

if __name__ == "__main__":
    ref, hyp = open(sys.argv[1]).read(), open(sys.argv[2]).read()
    s, ops = score(ref, hyp)
    line = f"WER {s['wer']*100:5.1f}%  (n={s['n']} S={s['S']} D={s['D']} I={s['I']})"
    if "--vocab" in sys.argv:
        vocab = [t.strip() for t in sys.argv[sys.argv.index("--vocab") + 1].split(",") if t.strip()]
        h, t, missed = vocab_hits(ref, hyp, vocab)
        line += f"  names {h}/{t}" + (f"  missed: {', '.join(missed)}" if missed else "")
    line += (f"  fillers {filler_count(hyp)} (ref {filler_count(ref)})"
             f"  repeats {repeat_count(hyp)} (ref {repeat_count(ref)})")
    print(line)
    if "--show" in sys.argv:
        for o in ops:
            if o[0] != "=": print(f"  {o[0]} {o[1]!r:>20} -> {o[2]!r}")
