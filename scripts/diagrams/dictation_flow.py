"""docs/images/dictation-flow.svg — one dictated passage, key down to text at the cursor.

Labels checked against Transcriberr/Dictation (DictationController,
UtteranceCapture, DictationText, DictationContext, TextInserter). Regenerate:
    <venv>/bin/python scripts/diagrams/dictation_flow.py
"""
import os

from litfield import INK, INK3, INK4, ROOT, Diagram

W = 1200
d = Diagram(W, 560,
            "How dictation works",
            "Hold a key in any app and talk. Parakeet decodes the whole passage on the Neural Engine, "
            "a deterministic text pass cleans it, the app in front decides how much to rewrite, and "
            "the text is pasted at the cursor.")

d.display(48, 84, "Hold a key, talk, let go.", size=34, weight=700, fill=INK)
d.display(48, 124, "The text lands where the cursor is.", size=34, weight=700, fill=INK4)
d.text(48, 158, "One passage, from key down to pasted text. On a 20 to 30 second passage the decode takes about 0.15 s.",
       size=15, fill=INK3)

d.panel(48, 196, W - 96, 316)
r = 236
d.node(72, r, 196, 112, "Key down", ["Right ⌥ by default,", "hold or tap to toggle;", "the app in front and the",
                                      "text before the caret are read"], line_size=12)
d.arrow([(268, r + 56), (290, r + 56)])
d.node(294, r, 196, 112, "Capture", ["microphone kept warm,", "so the first word", "is never clipped"])
d.arrow([(490, r + 56), (512, r + 56)])
d.node(516, r, 196, 112, "Parakeet", ["the whole passage at", "once on the Neural", "Engine, no streaming"],
       kind="night")
d.arrow([(712, r + 56), (734, r + 56)])
d.node(738, r, 196, 112, "Clean text", ["your spellings first,", "then stutters, fillers", "and spoken commands"])
d.arrow([(934, r + 56), (956, r + 56)])
d.node(960, r, 168, 112, "Paste", ["⌘V at the cursor,", "your clipboard put", "back afterwards"], kind="accent")

# per-app rule
ry = r + 140
d.arrow([(836, r + 112), (836, ry - 4)], dashed=True)
d.node(560, ry, 568, 100, "What the app in front decides", [
    "Terminals and editors get the words verbatim; most apps get the clean text.",
    "Chat and mail can get a smart pass: Gemma rewrites for the app and its tone,",
    "and the result is kept only if it is clearly the same passage.",
], line_size=12.5)
d.text(72, ry + 22, "Password fields are never read and always verbatim.", size=13, fill=INK4)
d.text(72, ry + 44, "Names that recur in your library feed the spellings,", size=13, fill=INK4)
d.text(72, ry + 62, "and each new one is offered as a one-tap chip.", size=13, fill=INK4)

d.save(os.path.join(ROOT, "docs", "images", "dictation-flow.svg"))
