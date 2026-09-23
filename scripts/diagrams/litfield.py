"""Lit Field primitives for static SVG diagrams in docs/img.

Tokens mirror ~/Documents/Landing/docs/lit-field-tokens.css (the same source
Transcriberr/UI/Theme/Theme.swift ports). A static SVG shown through <img>
gets no backdrop blur and cannot load web fonts, so this module:
  - paints the field itself and simulates veiled glass (translucent white,
    lit top edge, short offset contact shadow — never an outer stroke);
  - embeds Archivo + Schibsted Grotesk as WOFF2 subsets of exactly the
    glyphs a diagram uses (~10-20 KB each) — a silent fallback to a system
    face is the failure the design guide warns about;
  - measures every label with the real font metrics and refuses to write a
    diagram whose text overflows its box.

Needs fonttools + brotli (a throwaway venv is fine):
    python3 -m venv /tmp/lf && /tmp/lf/bin/pip install fonttools brotli
    /tmp/lf/bin/python scripts/diagrams/super.py
"""
import base64
import io
import os
from xml.sax.saxutils import escape

from fontTools.subset import Options, Subsetter
from fontTools.ttLib import TTFont

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
FONT_DIR = os.path.join(ROOT, "Transcriberr", "Resources", "Fonts")

# --- tokens ----------------------------------------------------------------
BASE = "#eceeed"
INK, INK2, INK3, INK4 = "#0b0c0e", "#23262b", "#454a52", "#5c626b"
ACCENT = "#ff4726"           # fills only on light; text only on night
ACCENT_ON_LIGHT = "#c03210"  # every accent text/stroke on a light ground
NIGHT, ON_NIGHT, ON_NIGHT2 = "#0b0c0e", "#f4f5f5", "#a9b0b8"
VEIL = "rgba(255,255,255,0.54)"
VEIL_STRONG = "rgba(255,255,255,0.88)"
HAIR = "rgba(11,12,14,0.12)"
DATA = ["#14507a", "#0f5d3a", "#7a4b00", "#5c626b"]  # data-viz series 2-5

FACES = {
    # family, weight -> file
    ("Archivo", 600): "Archivo-SemiBold.ttf",
    ("Archivo", 700): "Archivo-Bold.ttf",
    ("Schibsted Grotesk", 400): "SchibstedGrotesk-Regular.ttf",
    ("Schibsted Grotesk", 700): "SchibstedGrotesk-Bold.ttf",
}
_fonts = {}


def _font(key):
    if key not in _fonts:
        _fonts[key] = TTFont(os.path.join(FONT_DIR, FACES[key]))
    return _fonts[key]


def text_width(s, family, weight, size, tracking=0.0):
    f = _font((family, weight))
    cmap, hmtx, upem = f.getBestCmap(), f["hmtx"], f["head"].unitsPerEm
    adv = sum(hmtx[cmap.get(ord(c), cmap.get(0x20))][0] for c in s)
    return adv * size / upem + tracking * size * max(0, len(s) - 1)


class Diagram:
    def __init__(self, w, h, title, desc):
        self.w, self.h = w, h
        self.title, self.desc = title, desc
        self.body = []
        self.used = {k: set() for k in FACES}
        self.problems = []

    # --- text ----------------------------------------------------------------
    def text(self, x, y, s, family="Schibsted Grotesk", weight=400, size=13,
             fill=INK3, anchor="start", tracking=0.0, max_width=None):
        self.used[(family, weight)].update(s)
        wdt = text_width(s, family, weight, size, tracking)
        if max_width is not None and wdt > max_width + 0.5:
            self.problems.append(f"overflow {wdt:.0f}>{max_width:.0f}px: {s!r}")
        ls = f' letter-spacing="{tracking}em"' if tracking else ""
        self.body.append(
            f'<text x="{x:g}" y="{y:g}" font-family="{family}" font-weight="{weight}" '
            f'font-size="{size}" fill="{fill}" text-anchor="{anchor}"{ls}>{escape(s)}</text>')
        return wdt

    def display(self, x, y, s, size=15, fill=INK, weight=600, **kw):
        tr = -0.025 if size >= 18 else 0.0
        return self.text(x, y, s, "Archivo", weight, size, fill, tracking=tr, **kw)

    # --- surfaces -------------------------------------------------------------
    def panel(self, x, y, w, h, r=22, fill=VEIL, lift=1):
        """Veiled glass: translucent fill, lit top edge, contact shadow.
        border: 0 — a panel's outer edge is never stroked."""
        self.body.append(
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" filter="url(#lift{lift})"/>')
        self._edge(x, y, w, r)

    def _edge(self, x, y, w, r):
        self.body.append(
            f'<path d="M{x + r * 0.55:g},{y + 0.75:g} H{x + w - r * 0.55:g}" '
            f'stroke="rgba(255,255,255,0.9)" stroke-width="1.5" stroke-linecap="round"/>')

    def node(self, x, y, w, h, title, lines=(), kind="card", pad=16, title_size=15,
             line_size=12.5, line_gap=17, r=12, title_y=None):
        """A step. kind: card (glass), night (inverted emphasis), accent
        (the one result the eye should land on — ink on accent, never white)."""
        if kind == "card":
            fill, tc, lc = VEIL_STRONG, INK, INK3
        elif kind == "night":
            fill, tc, lc = NIGHT, ON_NIGHT, ON_NIGHT2
        else:
            fill, tc, lc = ACCENT, INK, INK2
        self.body.append(
            f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill}" filter="url(#lift1)"/>')
        if kind != "night":
            self._edge(x, y, w, r)
        ty = title_y if title_y is not None else y + pad + title_size * 0.8
        self.display(x + pad, ty, title, size=title_size, fill=tc, max_width=w - 2 * pad)
        ly = ty + line_gap + 4
        for ln in lines:
            color = lc
            if isinstance(ln, tuple):
                ln, color = ln
                if color == "accent":
                    color = ACCENT if kind == "night" else ACCENT_ON_LIGHT
            self.text(x + pad, ly, ln, size=line_size, fill=color, max_width=w - 2 * pad)
            ly += line_gap
        if ly - line_gap + 8 > y + h:
            self.problems.append(f"node {title!r}: text runs to {ly - line_gap + 8:.0f}, box ends {y + h}")

    # --- connectors -------------------------------------------------------------
    def arrow(self, pts, color=INK3, dashed=False, head=True):
        d = " ".join(f"{x:g},{y:g}" for x, y in pts)
        dash = ' stroke-dasharray="5 5"' if dashed else ""
        mk = f' marker-end="url(#{"arrA" if color == ACCENT_ON_LIGHT else "arr"})"' if head else ""
        self.body.append(
            f'<polyline points="{d}" fill="none" stroke="{color}" stroke-width="1.6" '
            f'stroke-linecap="round" stroke-linejoin="round"{dash}{mk}/>')

    def rule(self, x1, y, x2):
        """Internal divider — inside a panel only."""
        self.body.append(f'<line x1="{x1}" y1="{y}" x2="{x2}" y2="{y}" stroke="{HAIR}" stroke-width="1"/>')

    def raw(self, s):
        self.body.append(s)

    # --- output -------------------------------------------------------------------
    def _font_css(self):
        css = []
        for (family, weight), chars in self.used.items():
            if not chars:
                continue
            f = TTFont(os.path.join(FONT_DIR, FACES[(family, weight)]))
            opts = Options()
            opts.flavor = "woff2"
            opts.layout_features = ["kern", "liga", "ss01", "tnum"]
            opts.name_IDs = []
            opts.notdef_outline = True
            sub = Subsetter(opts)
            sub.populate(text="".join(sorted(chars)) + " ")
            sub.subset(f)
            buf = io.BytesIO()
            f.flavor = "woff2"
            f.save(buf)
            b64 = base64.b64encode(buf.getvalue()).decode()
            css.append(f"@font-face{{font-family:'{family}';font-weight:{weight};"
                       f"src:url(data:font/woff2;base64,{b64}) format('woff2');}}")
        css.append("text{font-feature-settings:'ss01' 1;}")
        return "".join(css)

    def field(self):
        """The continuous light field (tokens: .lit-field), bloom held still."""
        return f"""
  <radialGradient id="fCool" cx="6%" cy="10%" r="95%"><stop offset="0" stop-color="#b9c8d2"/><stop offset="0.58" stop-color="#b9c8d2" stop-opacity="0"/></radialGradient>
  <radialGradient id="fWarm" cx="90%" cy="14%" r="75%"><stop offset="0" stop-color="#ffd9b8"/><stop offset="0.62" stop-color="#ffd9b8" stop-opacity="0"/></radialGradient>
  <radialGradient id="fEmber" cx="76%" cy="92%" r="65%"><stop offset="0" stop-color="#ffcfa8"/><stop offset="0.64" stop-color="#ffcfa8" stop-opacity="0"/></radialGradient>
  <radialGradient id="fHaze" cx="26%" cy="84%" r="90%"><stop offset="0" stop-color="#cfd8d6"/><stop offset="0.62" stop-color="#cfd8d6" stop-opacity="0"/></radialGradient>
  <linearGradient id="fBase" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#dbe3e7"/><stop offset="0.46" stop-color="#e9e6df"/><stop offset="1" stop-color="#f7e6d4"/></linearGradient>
  <radialGradient id="fBloom" cx="72%" cy="18%" r="40%"><stop offset="0" stop-color="#ff9e60" stop-opacity="0.32"/><stop offset="1" stop-color="#ff9e60" stop-opacity="0"/></radialGradient>
  <filter id="lift1" x="-10%" y="-10%" width="120%" height="140%">
    <feDropShadow dx="0" dy="1" stdDeviation="0.6" flood-color="#10141c" flood-opacity="0.06"/>
    <feDropShadow dx="0" dy="4" stdDeviation="4" flood-color="#10141c" flood-opacity="0.16"/>
  </filter>
  <filter id="lift2" x="-10%" y="-10%" width="120%" height="140%">
    <feDropShadow dx="0" dy="1" stdDeviation="1" flood-color="#10141c" flood-opacity="0.06"/>
    <feDropShadow dx="0" dy="8" stdDeviation="8" flood-color="#10141c" flood-opacity="0.20"/>
  </filter>
  <marker id="arr" markerWidth="10" markerHeight="10" refX="7" refY="4" orient="auto" markerUnits="userSpaceOnUse">
    <path d="M1,1 L7,4 L1,7" fill="none" stroke="{INK3}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
  </marker>
  <marker id="arrA" markerWidth="10" markerHeight="10" refX="7" refY="4" orient="auto" markerUnits="userSpaceOnUse">
    <path d="M1,1 L7,4 L1,7" fill="none" stroke="{ACCENT_ON_LIGHT}" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/>
  </marker>"""

    def save(self, path):
        if self.problems:
            raise SystemExit("layout problems:\n  " + "\n  ".join(self.problems))
        w, h = self.w, self.h
        svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" aria-labelledby="t d">
<title id="t">{escape(self.title)}</title>
<desc id="d">{escape(self.desc)}</desc>
<defs>
  <style>{self._font_css()}</style>{self.field()}
</defs>
<rect width="{w}" height="{h}" fill="{BASE}"/>
<rect width="{w}" height="{h}" fill="url(#fBase)"/>
<rect width="{w}" height="{h}" fill="url(#fCool)"/>
<rect width="{w}" height="{h}" fill="url(#fWarm)"/>
<rect width="{w}" height="{h}" fill="url(#fEmber)"/>
<rect width="{w}" height="{h}" fill="url(#fHaze)"/>
<rect width="{w}" height="{h}" fill="url(#fBloom)"/>
{chr(10).join(self.body)}
</svg>
"""
        with open(path, "w") as fh:
            fh.write(svg)
        print(f"wrote {os.path.relpath(path, ROOT)} ({len(svg) // 1024} KB)")
