"""docs/img/super.svg — how a Super run works, stage by stage.

Every label here was checked against the code (EnsembleBackend,
TranscriptionRunner, InferenceGate, MeetingBrief). Change the code, change
this file, then regenerate:  <venv>/bin/python scripts/diagrams/super.py
"""
import os

from litfield import ACCENT, ACCENT_ON_LIGHT, DATA, INK, INK3, INK4, NIGHT, ROOT, VEIL, Diagram

W = 1200
d = Diagram(W, 1738,
            "How Super works",
            "Two speech engines transcribe every chunk in parallel and a word vote merges them. "
            "Gemma reads the whole transcript, then rules only on the chunks where the engines "
            "disagreed. Everything runs on the Mac.")

# --- headline --------------------------------------------------------------
d.display(48, 84, "Two engines hear every chunk.", size=34, weight=700, fill=INK)
d.display(48, 124, "Gemma rules only where they disagree.", size=34, weight=700, fill=INK4)
d.text(48, 158, "How a Super run turns a recording into one transcript. Everything runs on the Mac.",
       size=15, fill=INK3)


def section(y, h, title, note=None):
    d.panel(48, y, W - 96, h)
    d.display(72, y + 38, title, size=19, weight=700)
    if note:
        d.text(W - 72, y + 38, note, size=13, fill=INK4, anchor="end")


# --- audio in ----------------------------------------------------------------
Y = 196
section(Y, 236, "Audio in", "split-track meeting: your mic and the call are recorded apart")
r1, r2 = Y + 64, Y + 148
d.node(72, r1, 200, 68, "Mic track", ["you, labelled Me"])
d.arrow([(272, r1 + 34), (302, r1 + 34)])
d.node(306, r1, 196, 68, "Echo cancel", ["NLMS: the call's echo out"])
d.arrow([(502, r1 + 34), (532, r1 + 34)])
d.node(72, r2, 200, 68, "System track", ["the call, via the audio tap"])
d.arrow([(272, r2 + 34), (532, r2 + 34)])
d.node(536, r1, 220, 152, "Chunker",
       ["at most 28 s, cut in silence", "1 s recap at every seam,", "so no word is lost at a cut",
        "both tracks, one timeline"])
d.arrow([(172, r2 + 68), (172, r2 + 80), (855, r2 + 80), (855, r2 + 72)], dashed=True)
d.node(782, r2, 152, 68, "Diarizer", ["tells the others apart"], line_size=12)
d.node(946, r1, 182, 152, "Engine pair",
       ["Merge A × Merge B", "default: Parakeet v3 × v2", "non-English: Whisper",
        "replaces v2 and leads", ("referee: Gemma 4, text", "accent")], line_size=12)
d.arrow([(646, r1 + 152), (646, Y + 236 + 36)])
d.text(657, Y + 236 + 24, "chunks", size=12.5, fill=INK4)

# --- pass 1 ------------------------------------------------------------------
Y = 468
section(Y, 548, "Pass 1: every chunk, three at a time", "Gemma stays idle: the engines get the hardware")
cy = Y + 128  # flow centre line
d.node(72, cy - 36, 118, 72, "Chunk", ["about 26 s"])
d.arrow([(190, cy), (218, cy)])
d.node(222, cy - 40, 156, 80, "Silent?", ["loudest 200 ms", "below 0.005 RMS"])
d.arrow([(300, cy + 40), (300, cy + 62)], color=ACCENT_ON_LIGHT)
d.text(300, cy + 80, "yes: skip, no engine runs", size=12.5, fill=ACCENT_ON_LIGHT, anchor="middle")
d.arrow([(378, cy), (396, cy), (396, cy - 38), (410, cy - 38)])
d.arrow([(396, cy), (396, cy + 38), (410, cy + 38)])
d.text(414, cy - 80, "in parallel, each word with a confidence", size=12.5, fill=INK4)
d.node(414, cy - 66, 206, 58, "Engine A", ["e.g. Whisper v3, GPU and ANE"], kind="night",
       title_size=14, line_gap=16, pad=14)
d.node(414, cy + 8, 206, 58, "Engine B", ["e.g. Parakeet v3, ANE"], title_size=14, line_gap=16, pad=14)
d.text(414, cy + 90, "Whisper already drops sign-offs and the", size=12, fill=INK4)
d.text(414, cy + 106, "stock lines it writes over its padding", size=12, fill=INK4)
d.arrow([(620, cy - 38), (634, cy - 38), (634, cy), (650, cy)])
d.arrow([(620, cy + 38), (634, cy + 38), (634, cy)], head=False)
d.node(654, cy - 40, 176, 80, "Phantom?", ["“Thank you” only one", "engine heard: dropped"])
d.arrow([(830, cy), (852, cy)])
d.node(856, cy - 40, 134, 80, "Agree?", ["Dice score over", "both word lists"])
d.arrow([(990, cy), (1008, cy)])
d.node(1012, cy - 48, 116, 96, "Word vote", ["ROVER: align,", "then decide", "word by word"], kind="accent")

# the inference gate
gx, gy, gw, gh = 72, Y + 262, 520, 186
d.node(gx, gy, gw, gh, "The inference gate", [
    "Whisper and Parakeet share it: three chunks × two engines",
    "run at once. Gemma takes it alone; LiteRT hangs if another",
    "engine infers beside it. A waiting Gemma call holds back new",
    "shared calls, so it is never starved.",
])
tl = gy + gh - 42  # mini timeline
bars = [(0, 150, 0, DATA[0]), (30, 130, 1, DATA[3]), (60, 170, 2, DATA[0])]
for x0, x1, lane, c in bars:
    d.raw(f'<rect x="{gx + 16 + x0}" y="{tl + lane * 9}" width="{x1 - x0}" height="6" rx="3" fill="{c}"/>')
d.raw(f'<rect x="{gx + 200}" y="{tl + 4}" width="120" height="14" rx="7" fill="{ACCENT}"/>')
d.text(gx + 260, tl + 15, "Gemma alone", size=11, fill=INK, anchor="middle")
for x0, x1, lane, c in [(338, 470, 0, DATA[0]), (352, 440, 1, DATA[3])]:
    d.raw(f'<rect x="{gx + 16 + x0}" y="{tl + lane * 9}" width="{x1 - x0}" height="6" rx="3" fill="{c}"/>')
d.text(gx + 16, tl + 36, "Whisper", size=11, fill=DATA[0])
d.text(gx + 76, tl + 36, "Parakeet", size=11, fill=DATA[3])
d.text(gx + gw - 16, tl + 36, "time →", size=11, fill=INK4, anchor="end")

# how the vote decides
vx, vy, vw = 624, Y + 262, 504
rules = [
    ("Same word", "the trusted engine's spelling and punctuation"),
    ("In your vocabulary", "that reading wins"),
    ("Latin vs a guess", "the trusted engine's Latin beats a native-script guess"),
    ("Otherwise", "confidence × language prior (weak engine × 0.5)"),
    ("Stray extra words", "from the weak engine dropped, unless 3+ in a row"),
]
d.node(vx, vy, vw, 186, "How one disputed word is decided")
for i, (k, v) in enumerate(rules):
    ry = vy + 60 + i * 26
    if i:
        d.rule(vx + 16, ry - 17, vx + vw - 16)
    d.display(vx + 16, ry, k, size=12.5, fill=INK, max_width=150)
    d.text(vx + 172, ry, v, size=12.5, fill=INK3, max_width=vw - 188)
d.arrow([(1070, cy + 48), (1070, vy - 4)], color=ACCENT_ON_LIGHT, dashed=True, head=False)

# store + max-quality-off note
sy = Y + 470
d.arrow([(1128, cy), (1144, cy), (1144, sy - 12), (1070, sy - 12), (1070, sy - 2)])
d.node(878, sy, 250, 62, "Clean the seams", ["recap repeat trimmed, echo dropped"],
       title_size=14, line_gap=16, pad=14)
d.arrow([(878, sy + 31), (866, sy + 31)])
d.node(540, sy, 322, 62, "Stored per chunk", ["voted text (shown live), raw A, raw B, agreement"],
       kind="night", title_size=14, line_gap=16, pad=14)
d.text(72, sy + 22, "With Max quality off there is no pass 2: a chunk", size=12.5, fill=INK4)
d.text(72, sy + 40, "agreeing below 0.5 goes to Gemma right here,", size=12.5, fill=INK4)
d.text(72, sy + 58, "with only the text before it as context.", size=12.5, fill=INK4)

# --- pass 2 ------------------------------------------------------------------
Y = 1052
d.arrow([(701, sy + 62), (701, Y - 4)])
section(Y, 330, "Pass 2: Gemma reads first, then rules", "Max quality only")
py = Y + 68
d.node(72, py, 300, 150, "Read the whole transcript", [
    "in sections of about 3,000 tokens",
    "(larger reads were measured to hang)",
    ("Brief: topic, people, names", INK),
    ("as spelled in this recording", INK),
    "plus spelling fixes that pass guards",
])
d.arrow([(372, py + 75), (400, py + 75)])
d.node(404, py, 222, 150, "Pick the disputes", [
    ("agreement below 0.8", INK), ("the worst 10, no more", INK),
    "every other chunk keeps", "its word vote",
])
d.arrow([(626, py + 75), (654, py + 75)])
d.node(658, py, 280, 150, "Gemma rules", [
    "sees raw A and raw B, the text",
    "before and after the chunk,",
    "your vocabulary and the brief",
    ("told to choose between the", "accent"),
    ("readings, never to invent", "accent"),
], kind="night")
d.arrow([(938, py + 75), (966, py + 75)])
d.node(970, py, 158, 150, "Splice", [
    "the ruling replaces", "the chunk's text",
    ("over 120 s: the", "accent"), ("chunk keeps its vote", "accent"),
])
d.text(72, py + 190, "Why two passes: most chunks agree and never needed context. Pass 1 runs flat out, and the slow",
       size=14, fill=INK3)
d.text(72, py + 210, "judgment is spent afterwards, only where the engines fought, with context from both sides.",
       size=14, fill=INK3)
d.text(72, py + 240, "Measured on a 42-minute meeting: pass 1 was about 96% of the run, pass 2 about a minute. "
       "v3.8.0 overlap: 6-min slice 241 s → 183 s.", size=12.5, fill=INK4)

# --- finalize ------------------------------------------------------------------
Y = 1418
d.arrow([(600, 1382), (600, Y - 4)])
section(Y, 158, "Finalize")
fy = Y + 62
d.node(72, fy, 232, 76, "Apply fixes", ["the brief's guarded spellings"])
d.arrow([(304, fy + 34), (332, fy + 34)])
d.node(336, fy, 252, 76, "Echo scrub", ["a call line heard again on your", "mic: one copy kept"])
d.arrow([(588, fy + 34), (616, fy + 34)])
d.node(620, fy, 300, 76, "Speakers and names", ["mic lines are you, the diarizer", "labels the others, names from the talk"])
d.arrow([(920, fy + 34), (948, fy + 34)])
d.node(952, fy, 176, 76, "Transcript", ["saved as a new version"], kind="accent")

# --- hangs -----------------------------------------------------------------------
Y = 1612
d.panel(48, Y, W - 96, 98, fill=VEIL)
d.display(72, Y + 36, "If an engine hangs", size=17, weight=700)
d.text(72, Y + 62, "A chunk over 120 s: the engine is rebuilt and the chunk retried; stuck again, the healthy engine does it alone.",
       size=13.5, fill=INK3, max_width=W - 144)
d.text(72, Y + 82, "Two hangs in one run: Gemma is benched and the rest of the run is single-engine, so the run still finishes.",
       size=13.5, fill=INK3, max_width=W - 144)

d.save(os.path.join(ROOT, "docs", "img", "super.svg"))
