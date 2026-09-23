#!/usr/bin/env python3
"""Score a transcript against a hand-checked reference.

    eval_wer.py <reference.txt> <hypothesis.txt> [--vocab "A, B, C"] [--show]

Both files are plain text. Filler words (um, uh, угу, ...) and punctuation
are ignored on both sides, so a reading that keeps disfluencies is not
punished for them. Prints WER with its substitution/deletion/insertion split,
and, with --vocab, how many vocabulary terms that occur in the reference were
written exactly that way in the hypothesis (case-sensitive: "Blitz" for
"Blits" is a miss).
"""
import re, sys

FILLERS = {"um", "uh", "uhm", "hmm", "mm", "mhm", "ah", "eh", "er", "erm", "oh",
           "е", "ем", "еее", "ее", "м", "мм", "ну", "угу", "ага", "а-а", "хм"}

# Spelled-out English numbers score the same as digits ("twelve" = "12").
NUMBERS = {w: str(i) for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen "
    "fifteen sixteen seventeen eighteen nineteen twenty".split())}
NUMBERS.update({"thirty": "30", "forty": "40", "fifty": "50", "hundred": "100"})

def words(text):
    text = text.lower().replace("’", "'").replace("ʼ", "'")
    ws = re.findall(r"[^\W_]+(?:'[^\W_]+)*", text)  # hyphens split: "A-B" = "A/B", "man-hours" = "man hours"
    return [NUMBERS.get(w, w) for w in ws if w not in FILLERS]

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
    print(line)
    if "--show" in sys.argv:
        for o in ops:
            if o[0] != "=": print(f"  {o[0]} {o[1]!r:>20} -> {o[2]!r}")
