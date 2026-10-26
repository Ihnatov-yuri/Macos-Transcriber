"""docs/images/overview.svg — the whole app on one page, for the README.

Labels were checked against the code (AudioRecorder, VoiceProcessedMic,
EnsembleBackend, PeopleStore, KBService). Regenerate:
    <venv>/bin/python scripts/diagrams/overview.py
"""
import os

from litfield import INK, INK3, INK4, ROOT, Diagram

W = 1200
d = Diagram(W, 900,
            "How Transcriberr works",
            "Audio from the microphone, the call or a file goes through on-device speech engines, "
            "a diarizer and voice prints, then a local text model, and lands in a library that "
            "assistants can read through a read-only MCP server. Nothing leaves the Mac.")

d.display(48, 84, "One recording, start to finish.", size=34, weight=700, fill=INK)
d.display(48, 124, "Every step runs on the Mac.", size=34, weight=700, fill=INK4)
d.text(48, 158, "Cloud engines exist for those who want them. They are off until you add a key.",
       size=15, fill=INK3)


def section(y, h, title, note=None):
    d.panel(48, y, W - 96, h)
    d.display(72, y + 38, title, size=19, weight=700)
    if note:
        d.text(W - 72, y + 38, note, size=13, fill=INK4, anchor="end", max_width=620)


# --- capture -------------------------------------------------------------------
Y = 196
section(Y, 172, "Capture", "one drift-compensated clock for every source")
r = Y + 64
nodes = [
    ("Microphone", ["Apple echo filter in meetings"]),
    ("The call", ["system audio, process tap"]),
    ("A file", ["import, drag and drop"]),
    ("Dictation key", ["hold Right ⌥ in any app"]),
]
x = 72
for t, lines in nodes:
    d.node(x, r, 240, 76, t, lines)
    x += 264
d.text(72, r + 100, "Meetings keep the mic and the call on separate tracks, so your own lines are always yours.",
       size=13, fill=INK4)

# --- recognise ------------------------------------------------------------------
Y = 404
d.arrow([(600, 368), (600, Y - 4)])
section(Y, 196, "Recognise", "Neural Engine and GPU, never the network")
r = Y + 64
d.node(72, r, 250, 100, "Parakeet v3 / UK", ["NVIDIA's 0.6B model in CoreML,", "on the Neural Engine,",
                                             "about 100× real time"])
d.node(338, r, 250, 100, "Whisper large-v3", ["WhisperKit, decoder on the GPU,", "the strongest for Ukrainian",
                                               "and rarer languages"])
d.node(604, r, 250, 100, "Super", ["two engines vote word by word,", ("Gemma rules where they differ", "accent"),
                                    "slow, and the most accurate"], kind="night")
d.node(870, r, 258, 100, "Who spoke", ["pyannote diarizer, then voice", "prints match saved People",
                                        "and name them"])

# --- understand ---------------------------------------------------------------
Y = 636
d.arrow([(600, 600), (600, Y - 4)])
section(Y, 120, "Understand", "Gemma 4 through Google's LiteRT-LM, loaded only while it works")
r = Y + 56
d.node(72, r, 344, 50, "Titles, summaries, minutes", [], title_y=r + 31)
d.node(432, r, 336, 50, "Your own presets and rewrites", [], title_y=r + 31)
d.node(784, r, 344, 50, "Person briefs and speech goals", [], title_y=r + 31)

# --- keep ------------------------------------------------------------------------
Y = 792
d.arrow([(600, 756), (600, Y - 4)])
d.node(48, Y, 540, 76, "Library", ["every run kept as a version, audio as AAC,",
                                    "sidecars that round-trip with the Android app"])
d.arrow([(588, Y + 38), (608, Y + 38)])
d.node(612, Y, 540, 76, "transcriberrcli and MCP", [("read-only: AI assistants can search the", INK),
                                                     ("library and never change it", INK)], kind="accent")

d.save(os.path.join(ROOT, "docs", "images", "overview.svg"))
