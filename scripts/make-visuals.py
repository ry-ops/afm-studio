#!/usr/bin/env python3
"""Draws the animated SVGs in docs/images. Standard library only.

    python3 scripts/make-visuals.py

Every number and line of model output below was captured from real runs of `afm` on an
Apple M1 with macOS 27.0.1. Re-capture them when the model changes, then re-run this script.
The SVGs animate with CSS and SMIL only (no script), so they play inside a GitHub README.
"""
import html
import os
import textwrap

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "images")

SANS = "ui-sans-serif, -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', Helvetica, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace"

BG, CARD, EDGE = "#0b0d12", "#12151d", "#262b38"
TEXT, DIM, FAINT = "#e8eaf0", "#8a92a6", "#4a5163"
BLUE, INDIGO, PINK, ORANGE, GREEN = "#5ac8fa", "#7d7aff", "#ff6fae", "#ffb340", "#5be37d"
GLOW = [BLUE, INDIGO, PINK, ORANGE]


def esc(s):
    return html.escape(s, quote=True)


class Timeline:
    """Turns seconds into keyframe percentages for one looping cycle of `duration` seconds."""

    def __init__(self, duration, fade=0.6):
        self.d = duration
        self.fade = fade
        self.rules = []
        self.n = 0

    def p(self, t):
        return max(0.0, min(100.0, t / self.d * 100))

    def _name(self):
        self.n += 1
        return f"k{self.n}"

    def appear(self, t, until=None, ease=0.25):
        """Class name for an element that fades in at t and stays until `until` (default: cycle end)."""
        name = self._name()
        end = until if until is not None else self.d - self.fade
        a, b, c, e = self.p(t), self.p(t + ease), self.p(end), self.p(end + (ease if until else self.fade))
        self.rules.append(f"@keyframes {name}{{0%,{a:.3f}%{{opacity:0}}{b:.3f}%,{c:.3f}%{{opacity:1}}{min(e, 100):.3f}%,100%{{opacity:0}}}}"
                          f".{name}{{opacity:0;animation:{name} {self.d}s linear infinite}}")
        return name

    def slide(self, t0, t1, dx, steps=None):
        """Class for an element moved right by dx between t0 and t1 (stepped when `steps` is set)."""
        name = self._name()
        a, b = self.p(t0), self.p(t1)
        fn = f"steps({steps},end)" if steps else "linear"
        self.rules.append(f"@keyframes {name}{{0%,{a:.3f}%{{transform:translateX(0)}}{b:.3f}%,100%{{transform:translateX({dx:.2f}px)}}}}"
                          f".{name}{{animation:{name} {self.d}s {fn} infinite}}")
        return name

    def grow(self, t0, t1):
        """Class for a bar that scales from 0 to full width (from its left edge) between t0 and t1."""
        name = self._name()
        a, b, c = self.p(t0), self.p(t1), self.p(self.d - self.fade)
        self.rules.append(f"@keyframes {name}{{0%,{a:.3f}%{{transform:scaleX(0)}}{b:.3f}%,{c:.3f}%{{transform:scaleX(1)}}100%{{transform:scaleX(1)}}}}"
                          f".{name}{{transform-box:fill-box;transform-origin:0 50%;transform:scaleX(0);animation:{name} {self.d}s linear infinite}}")
        return name

    def jumps(self, stops):
        """Class for an element that jumps vertically: stops is [(t, dy), ...] in time order."""
        name = self._name()
        frames, prev = ["0%{transform:translateY(0)}"], 0
        for t, dy in stops:
            frames.append(f"{max(self.p(t) - 0.01, 0):.3f}%{{transform:translateY({prev}px)}}")
            frames.append(f"{self.p(t):.3f}%{{transform:translateY({dy}px)}}")
            prev = dy
        frames.append(f"100%{{transform:translateY({prev}px)}}")
        self.rules.append(f"@keyframes {name}{{{''.join(frames)}}}.{name}{{animation:{name} {self.d}s linear infinite}}")
        return name

    def motion(self, t0, t1):
        """SMIL attributes that move an element along a path between t0 and t1, every cycle."""
        assert 0 <= t0 < t1 <= self.d, f"motion {t0}-{t1} doesn't fit a {self.d}s cycle"
        a, b = t0 / self.d, t1 / self.d
        return f'dur="{self.d}s" repeatCount="indefinite" keyPoints="0;0;1;1" keyTimes="0;{a:.4f};{b:.4f};1" calcMode="linear"'

    def css(self):
        return "\n".join(self.rules)


def svg(w, h, body, css, title, desc):
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-labelledby="t d">
<title id="t">{esc(title)}</title>
<desc id="d">{esc(desc)}</desc>
<style>
.sans{{font-family:{SANS}}}
.mono{{font-family:{MONO}}}
@media (prefers-reduced-motion: reduce){{*{{animation-duration:0s!important;animation-delay:0s!important}}}}
{css}
</style>
{body}
</svg>
"""


def gradient(id_, x1="0", y1="0", x2="1", y2="0", colors=GLOW):
    stops = "".join(f'<stop offset="{i / (len(colors) - 1):.2f}" stop-color="{c}"/>' for i, c in enumerate(colors))
    return f'<linearGradient id="{id_}" x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}">{stops}</linearGradient>'


def card_frame(w, h, title=None):
    out = f'<rect width="{w}" height="{h}" rx="18" fill="{BG}"/>'
    out += f'<rect x="0.5" y="0.5" width="{w - 1}" height="{h - 1}" rx="17.5" fill="none" stroke="{EDGE}"/>'
    if title:
        out += f'<text x="28" y="38" class="sans" font-size="14" font-weight="600" fill="{DIM}" letter-spacing="1.4">{esc(title.upper())}</text>'
    return out


# MARK: Hero

def hero():
    W, H = 1280, 420
    tl = Timeline(9.0, fade=0)
    cx, cy = 922, 212
    nodes = [("AFM Studio app", 712, 100, BLUE), ("afm CLI", 712, 324, ORANGE),
             ("Claude via MCP", 1132, 100, PINK), ("OpenAI API", 1132, 324, INDIGO)]
    b = [f"<defs>{gradient('g')}{gradient('gv', '0', '0', '0', '1')}"
         f'<radialGradient id="halo"><stop offset="0" stop-color="{INDIGO}" stop-opacity=".55"/><stop offset="1" stop-color="{INDIGO}" stop-opacity="0"/></radialGradient>'
         f'<pattern id="dots" width="22" height="22" patternUnits="userSpaceOnUse"><circle cx="1" cy="1" r="1" fill="{FAINT}" opacity=".35"/></pattern>'
         f'<clipPath id="clip"><rect width="{W}" height="{H}" rx="18"/></clipPath></defs>']
    b.append(card_frame(W, H))
    b.append(f'<g clip-path="url(#clip)"><rect width="{W}" height="{H}" fill="url(#dots)"/>')
    # Words drifting up behind everything: the kind of work the model does.
    words = ["summarize", "extract", "{ \"city\": \"Austin\" }", "translate", "tags", "proofread", "classify",
             "key-points", "sentiment", "rewrite", "outline", "tokens: 4096", "action-items", "commit-message"]
    css_extra = []
    for i, wd in enumerate(words):
        x = 40 + (i * 157) % 1200
        dur = 16 + (i % 5) * 3
        delay = -(i * 2.3)
        name = f"drift{i}"
        css_extra.append(f"@keyframes {name}{{from{{transform:translateY(0)}}to{{transform:translateY(-{H + 80}px)}}}}"
                         f".{name}{{animation:{name} {dur}s linear {delay}s infinite}}")
        b.append(f'<text class="mono {name}" x="{x}" y="{H + 40}" font-size="13" fill="{DIM}" opacity=".10">{esc(wd)}</text>')
    b.append("</g>")
    # Left: name and promise.
    b.append(f'<text x="64" y="150" class="sans" font-size="66" font-weight="800" fill="url(#g)" letter-spacing="-1.5">AFM Studio</text>')
    b.append(f'<text x="66" y="196" class="sans" font-size="23" fill="{TEXT}">Apple’s on-device foundation model,</text>')
    b.append(f'<text x="66" y="228" class="sans" font-size="23" fill="{TEXT}">everywhere you work on a Mac.</text>')
    pills = ["On device", "Offline", "Free", "Pure Swift"]
    x = 66
    for p in pills:
        wpx = 22 + len(p) * 8.6
        b.append(f'<rect x="{x}" y="262" width="{wpx:.0f}" height="30" rx="15" fill="{CARD}" stroke="{EDGE}"/>')
        b.append(f'<text x="{x + wpx / 2:.0f}" y="282" class="sans" font-size="14" fill="{DIM}" text-anchor="middle">{p}</text>')
        x += wpx + 10
    b.append(f'<text x="66" y="350" class="mono" font-size="15" fill="{DIM}">$ afm "Explain DNS like I’m new to networking"</text>')
    # Right: the Mac boundary, with every surface inside it.
    b.append(f'<rect x="604" y="40" width="636" height="344" rx="22" fill="none" stroke="{FAINT}" stroke-dasharray="6 7"/>')
    b.append(f'<rect x="628" y="30" width="190" height="22" fill="{BG}"/>')
    b.append(f'<text x="640" y="46" class="sans" font-size="13" font-weight="600" fill="{DIM}" letter-spacing="1.2">YOUR MAC · STAYS HERE</text>')
    # Halo and rings around the chip.
    b.append(f'<circle cx="{cx}" cy="{cy}" r="120" fill="url(#halo)"/>')
    for i in range(3):
        name = f"ring{i}"
        css_extra.append(f"@keyframes {name}{{0%{{transform:scale(.6);opacity:.0}}15%{{opacity:.55}}100%{{transform:scale(1.9);opacity:0}}}}"
                         f".{name}{{transform-box:fill-box;transform-origin:center;animation:{name} 3.6s ease-out {-i * 1.2}s infinite}}")
        b.append(f'<circle class="{name}" cx="{cx}" cy="{cy}" r="66" fill="none" stroke="url(#g)" stroke-width="1.5"/>')
    # Paths between each surface and the chip, with requests going in and replies coming back.
    for i, (label, nx, ny, col) in enumerate(nodes):
        left = nx < cx
        sx = nx + (80 if left else -80)
        ex = cx - 58 if left else cx + 58
        ey = cy + (-26 if ny < cy else 26)
        mid = (sx + ex) / 2
        d = f"M{sx},{ny} C{mid},{ny} {mid},{ey} {ex},{ey}"
        back = f"M{ex},{ey} C{mid},{ey} {mid},{ny} {sx},{ny}"
        b.append(f'<path id="p{i}" d="{d}" fill="none" stroke="{col}" stroke-opacity=".28" stroke-width="2"/>')
        b.append(f'<path id="r{i}" d="{back}" fill="none" stroke="none"/>')
        t0 = i * 1.6
        for k, (pid, start, color, r) in enumerate([(f"p{i}", t0, col, 5), (f"r{i}", t0 + 2.2, TEXT, 4)]):
            vis = tl.appear(start, until=start + 1.3, ease=0.12)
            b.append(f'<g class="{vis}"><circle r="{r + 6}" fill="{color}" opacity=".18"/><circle r="{r}" fill="{color}">'
                     f'</circle><animateMotion {tl.motion(start, start + 1.3)}><mpath href="#{pid}"/></animateMotion></g>')
        # The node itself.
        bw = 160
        bx = nx - bw / 2
        b.append(f'<rect x="{bx}" y="{ny - 24}" width="{bw}" height="48" rx="13" fill="{CARD}" stroke="{col}" stroke-opacity=".55"/>')
        b.append(f'<circle cx="{bx + 20}" cy="{ny}" r="4.5" fill="{col}"/>')
        b.append(f'<text x="{bx + 34}" y="{ny + 5}" class="sans" font-size="14.5" font-weight="600" fill="{TEXT}">{esc(label)}</text>')
    # The chip.
    pins = ""
    for k in range(5):
        o = -40 + k * 20
        pins += (f'<rect x="{cx + o - 3}" y="{cy - 70}" width="6" height="12" rx="2"/><rect x="{cx + o - 3}" y="{cy + 58}" width="6" height="12" rx="2"/>'
                 f'<rect x="{cx - 70}" y="{cy + o - 3}" width="12" height="6" rx="2"/><rect x="{cx + 58}" y="{cy + o - 3}" width="12" height="6" rx="2"/>')
    b.append(f'<g fill="{FAINT}">{pins}</g>')
    b.append(f'<rect x="{cx - 58}" y="{cy - 58}" width="116" height="116" rx="22" fill="{CARD}" stroke="url(#g)" stroke-width="2"/>')
    b.append(f'<text x="{cx}" y="{cy + 2}" class="sans" font-size="30" font-weight="800" fill="url(#g)" text-anchor="middle">AFM</text>')
    b.append(f'<text x="{cx}" y="{cy + 26}" class="sans" font-size="11.5" fill="{DIM}" text-anchor="middle" letter-spacing=".6">on-device model</text>')
    return svg(W, H, "\n".join(b), tl.css() + "\n" + "\n".join(css_extra), "AFM Studio",
               "AFM Studio: Apple's on-device model in the middle, reached from the app, the afm CLI, Claude over MCP and an OpenAI-compatible API, all inside your Mac.")


# MARK: Terminal

SESSION = [
    ('afm --tool calculator "What is 17.5% of 2,340?"', [
        ("  ⚙︎ calculator(17.5 * 2340 / 100)", ORANGE),
        ("409.5", TEXT),
        ("2.10s · 17 in · 6 out · tools: calculator(17.5 * 2340 / 100)", FAINT),
    ], 1.4),
    ("afm run sentiment < email.txt", [
        ("{", TEXT),
        ('  "sentiment": "mixed",', TEXT),
        ('  "confidence": 0.6,', TEXT),
        ('  "reason": "Compliments on turnaround offset by delivery issues."', TEXT),
        ("}", TEXT),
        ("1.46s · 70 in · 37 out · 25.3 tok/s", FAINT),
    ], 1.1),
    ('afm extract --fields "customer, city, request, deadline" < email.txt', [
        ("{", TEXT),
        ('  "customer": "Dana Whitfield",', TEXT),
        ('  "city": "Austin",', TEXT),
        ('  "request": "send a replacement for the cracked monitor stand",', TEXT),
        ('  "deadline": "Friday"', TEXT),
        ("}", TEXT),
        ("1.25s · 71 in · 45 out · 36.0 tok/s", FAINT),
    ], 1.0),
]


def json_colored(line, x, y, cw, size):
    """A JSON line with keys and values tinted, laid out on the monospace grid."""
    import re
    m = re.match(r'^(\s*)("[^"]+")(:\s)(.*)$', line)
    if not m:
        return f'<text x="{x}" y="{y}" class="mono" font-size="{size}" fill="{TEXT}" xml:space="preserve">{esc(line)}</text>'
    ind, key, colon, val = m.groups()
    parts, col = [], len(ind)
    for seg, color in [(key, BLUE), (colon, DIM), (val, GREEN if val.lstrip().startswith('"') else ORANGE)]:
        parts.append(f'<text x="{x + col * cw:.2f}" y="{y}" class="mono" font-size="{size}" fill="{color}" xml:space="preserve" '
                     f'textLength="{len(seg) * cw:.2f}" lengthAdjust="spacingAndGlyphs">{esc(seg)}</text>')
        col += len(seg)
    return "".join(parts)


def terminal():
    W, H = 920, 500
    size, cw, lh = 14, 8.4, 21
    top, left, visible = 72, 26, 20
    # Lay out the document and its timeline.
    t, lines, events = 0.8, [], []
    for cmd, out, wait in SESSION:
        type_t = len(cmd) * 0.042
        lines.append(("cmd", cmd, t, t + type_t))
        t += type_t + wait
        for text, color in out:
            lines.append(("out", (text, color), t, None))
            t += 0.09 if color != FAINT else 0.25
        t += 2.2
        lines.append(("gap", None, t, None))
    lines.append(("idle", None, t, None))
    end = t + 2.0
    tl = Timeline(end, fade=0.5)
    # Scroll so the newest line stays visible.
    stops = []
    for i, (_, _, at, _) in enumerate(lines):
        if i >= visible:
            stops.append((at, -(i - visible + 1) * lh))
    b = [f'<defs><clipPath id="body"><rect x="0" y="44" width="{W}" height="{H - 44}"/></clipPath></defs>']
    b.append(card_frame(W, H))
    b.append(f'<path d="M0.5,44 H{W - 0.5}" stroke="{EDGE}"/>')
    for i, c in enumerate(["#ff5f57", "#febc2e", "#28c840"]):
        b.append(f'<circle cx="{24 + i * 20}" cy="22" r="6" fill="{c}"/>')
    b.append(f'<text x="{W / 2}" y="27" class="sans" font-size="13" fill="{DIM}" text-anchor="middle">afm — zsh</text>')
    doc = tl.jumps(stops) if stops else ""
    b.append(f'<g clip-path="url(#body)"><g class="{doc}">')
    prompt = "~ ❯ "
    for i, (kind, data, at, done) in enumerate(lines):
        y = top + i * lh
        if kind == "cmd":
            vis = tl.appear(at - 0.3, ease=0.05)
            x0 = left + len(prompt) * cw
            width = len(data) * cw
            g = [f'<text x="{left}" y="{y}" class="mono" font-size="{size}" fill="{GREEN}" xml:space="preserve">{esc(prompt)}</text>',
                 f'<text x="{x0}" y="{y}" class="mono" font-size="{size}" fill="{TEXT}" xml:space="preserve" textLength="{width:.2f}" lengthAdjust="spacingAndGlyphs">{esc(data)}</text>',
                 f'<rect class="{tl.slide(at, done, width + cw, steps=len(data) + 1)}" x="{x0}" y="{y - 15}" width="{W}" height="{lh}" fill="{BG}"/>']
            cur = tl.appear(at - 0.3, until=done + 0.5, ease=0.02)
            g.append(f'<g class="{cur}"><rect class="{tl.slide(at, done, width, steps=len(data))}" x="{x0}" y="{y - 14}" width="{cw}" height="18" fill="{TEXT}" opacity=".85"/></g>')
            b.append(f'<g class="{vis}">{"".join(g)}</g>')
        elif kind == "out":
            text, color = data
            vis = tl.appear(at, ease=0.06)
            if color == TEXT and '"' in text:
                inner = json_colored(text, left, y, cw, size)
            else:
                inner = (f'<text x="{left}" y="{y}" class="mono" font-size="{size}" fill="{color}" xml:space="preserve" '
                         f'textLength="{len(text) * cw:.2f}" lengthAdjust="spacingAndGlyphs">{esc(text)}</text>')
            b.append(f'<g class="{vis}">{inner}</g>')
        elif kind == "idle":
            vis = tl.appear(at, ease=0.05)
            blink = "blink"
            b.append(f'<g class="{vis}"><text x="{left}" y="{y}" class="mono" font-size="{size}" fill="{GREEN}" xml:space="preserve">{esc(prompt)}</text>'
                     f'<rect class="{blink}" x="{left + len(prompt) * cw}" y="{y - 14}" width="{cw}" height="18" fill="{TEXT}" opacity=".85"/></g>')
    b.append("</g></g>")
    css = tl.css() + "\n@keyframes blink{0%,49%{opacity:.85}50%,100%{opacity:0}}.blink{animation:blink 1s steps(1) infinite}"
    return svg(W, H, "\n".join(b), css, "afm in the terminal",
               "A terminal session: afm uses its calculator tool, labels the sentiment of an email as JSON, and extracts fields from it as JSON, all on device.")


# MARK: Prose to JSON

EMAIL = ("Thanks for the quick turnaround on the invoice! One thing: the March 14 delivery to our Austin "
         "office arrived two days late, and the box was crushed. Can you send a replacement for the cracked "
         "monitor stand by Friday? — Dana Whitfield, Northwind Supply")
FIELDS = [  # key, value from the real run, the source spans it came from, color
    ("customer", "Dana Whitfield", ["Dana Whitfield"], BLUE),
    ("city", "Austin", ["Austin"], ORANGE),
    ("request", "send a replacement for the cracked monitor stand", ["send a replacement for the cracked monitor stand"], PINK),
    ("deadline", "Friday", ["Friday"], GREEN),
]


def prose_to_json():
    W, H = 1240, 490
    size, cw, lh = 15, 9.0, 28
    lx, ly, cols = 56, 184, 50
    rx, ry = 668, 150
    wrapped = textwrap.wrap(EMAIL, cols)
    flat, starts = "", []
    for ln in wrapped:
        starts.append(len(flat))
        flat += ln + " "

    def spans_for(phrase):
        """Rectangles (per wrapped line) covering a phrase in the email."""
        i = flat.index(phrase)
        rects, j = [], i
        while j < i + len(phrase):
            row = max(k for k, s in enumerate(starts) if s <= j)
            col = j - starts[row]
            take = min(i + len(phrase) - j, len(wrapped[row]) - col)
            rects.append((lx + col * cw, ly + row * lh, take * cw))
            j += take + 1
        return rects

    step = 2.1
    t0 = 1.6
    end = t0 + step * len(FIELDS) + 4.6
    tl = Timeline(end, fade=0.6)
    b = [f"<defs>{gradient('g')}<clipPath id=\"jp\"><rect x=\"641\" y=\"113\" width=\"566\" height=\"{H - 152}\" rx=\"13\"/></clipPath></defs>", card_frame(W, H)]
    b.append(f'<text x="52" y="58" class="sans" font-size="26" font-weight="700" fill="{TEXT}">Prose in, typed JSON out</text>')
    b.append(f'<text x="52" y="88" class="sans" font-size="15.5" fill="{DIM}">Guided generation: the model can only write JSON that fits your fields. It never leaves your Mac.</text>')
    # Panels.
    for x, label in [(32, "email.txt"), (640, 'afm extract --fields "customer, city, request, deadline"')]:
        b.append(f'<rect x="{x}" y="112" width="568" height="{H - 150}" rx="14" fill="{CARD}" stroke="{EDGE}"/>')
        b.append(f'<text x="{x + 20}" y="134" class="mono" font-size="12.5" fill="{DIM}">{esc(label)}</text>')
    # Highlights sit under the email text.
    for i, (key, val, phrases, col) in enumerate(FIELDS):
        at = t0 + i * step
        for phrase in phrases:
            for (x, y, w) in spans_for(phrase):
                cls = tl.appear(at, ease=0.3)
                b.append(f'<rect class="{cls}" x="{x - 3}" y="{y - 17}" width="{w + 6}" height="24" rx="5" fill="{col}" fill-opacity=".22" stroke="{col}" stroke-opacity=".7"/>')
    for r, ln in enumerate(wrapped):
        b.append(f'<text x="{lx}" y="{ly + 12 + r * lh - 12}" class="mono" font-size="{size}" fill="{TEXT}" xml:space="preserve" '
                 f'textLength="{len(ln) * cw:.2f}" lengthAdjust="spacingAndGlyphs">{esc(ln)}</text>')
    # The JSON, line by line, each fed by a particle from its source.
    jcw = 8.0
    braces_t = t0 - 0.5
    open_cls = tl.appear(braces_t, ease=0.2)
    b.append(f'<text class="mono {open_cls}" x="{rx}" y="{ry + 18}" font-size="14" fill="{TEXT}">{{</text>')
    for i, (key, val, phrases, col) in enumerate(FIELDS):
        at = t0 + i * step
        y = ry + 18 + (i + 1) * 30
        comma = "," if i < len(FIELDS) - 1 else ""
        line = f'  "{key}": "{val}"{comma}'
        sx, sy, sw = spans_for(phrases[0])[0]
        start = (sx + sw / 2, sy - 5)
        endp = (rx + 30, y - 5)
        path = f"M{start[0]:.0f},{start[1]:.0f} C{start[0] + 260:.0f},{start[1] - 60:.0f} {endp[0] - 200:.0f},{endp[1] + 40:.0f} {endp[0]:.0f},{endp[1]:.0f}"
        b.append(f'<path id="f{i}" d="{path}" fill="none" stroke="{col}" stroke-opacity="0" stroke-width="1.5"/>')
        trail = tl.appear(at + 0.3, until=at + 1.4, ease=0.2)
        b.append(f'<path class="{trail}" d="{path}" fill="none" stroke="{col}" stroke-opacity=".35" stroke-width="1.5" stroke-dasharray="3 5"/>')
        dot = tl.appear(at + 0.3, until=at + 1.2, ease=0.08)
        b.append(f'<g class="{dot}"><circle r="11" fill="{col}" opacity=".2"/><circle r="5" fill="{col}"/>'
                 f'<animateMotion {tl.motion(at + 0.3, at + 1.2)}><mpath href="#f{i}"/></animateMotion></g>')
        # The line types in where the particle lands.
        shown = line if len(line) <= 62 else line
        vis = tl.appear(at + 1.15, ease=0.05)
        width = len(shown) * jcw
        b.append(f'<g class="{vis}" clip-path="url(#jp)">{json_colored(shown, rx, y, jcw, 13.4)}'
                 f'<rect class="{tl.slide(at + 1.15, at + 1.15 + len(shown) * 0.012, width + jcw, steps=max(4, len(shown) // 3))}" x="{rx}" y="{y - 16}" width="{width + 20}" height="24" fill="{CARD}"/></g>')
        chip = tl.appear(at, ease=0.3)
    close_t = t0 + len(FIELDS) * step
    close_cls = tl.appear(close_t, ease=0.2)
    b.append(f'<text class="mono {close_cls}" x="{rx}" y="{ry + 18 + (len(FIELDS) + 1) * 30}" font-size="14" fill="{TEXT}">}}</text>')
    stats = tl.appear(close_t + 0.4, ease=0.3)
    b.append(f'<g class="{stats}"><text x="{rx}" y="{ry + 18 + (len(FIELDS) + 2) * 30 + 6}" class="mono" font-size="13" fill="{DIM}">1.25s · 71 in · 45 out · 36.0 tok/s · on device</text></g>')
    # Field chips along the bottom of the JSON panel, lighting up as each field fills.
    x = rx
    for i, (key, val, phrases, col) in enumerate(FIELDS):
        at = t0 + i * step
        wpx = 22 + len(key) * 8.4
        b.append(f'<rect x="{x}" y="{H - 82}" width="{wpx:.0f}" height="28" rx="14" fill="none" stroke="{FAINT}"/>')
        lit = tl.appear(at, ease=0.3)
        b.append(f'<rect class="{lit}" x="{x}" y="{H - 82}" width="{wpx:.0f}" height="28" rx="14" fill="{col}" fill-opacity=".18" stroke="{col}"/>')
        b.append(f'<text x="{x + wpx / 2:.0f}" y="{H - 63}" class="mono" font-size="13" fill="{TEXT}" text-anchor="middle">{key}</text>')
        x += wpx + 10
    return svg(W, H, "\n".join(b), tl.css(), "Prose to JSON",
               "An email on the left. Each extracted field lights up its source words, which flow into a JSON object on the right: customer Dana Whitfield, city Austin, request, deadline Friday.")


# MARK: Benchmark

# afm bench --rounds 3 on an Apple M1, macOS 27.0.1 (round 2): first token, total seconds, output tokens.
BENCH = [("Short answer", 0.37, 0.37, 2), ("Paragraph", 0.48, 3.45, 103), ("List", 0.53, 2.90, 89),
         ("Rewrite", 0.51, 0.72, 16), ("Reasoning", 0.49, 2.56, 107)]


def bench():
    W, H = 1240, 470
    x0, scale, top, row = 230, 210, 150, 52
    start = 1.0
    longest = max(t for _, _, t, _ in BENCH)
    end = start + longest + 4.5
    tl = Timeline(end, fade=0.6)
    timed = [(n, f, t, o) for n, f, t, o in BENCH if o >= 8 and t - f >= 0.05]
    speed = sum(o - 1 for _, _, _, o in timed) / sum(t - f for _, f, t, _ in timed)
    ttft = sorted(f for _, f, _, _ in BENCH)[len(BENCH) // 2]
    b = [f"<defs>{gradient('g')}{gradient('gen', colors=[INDIGO, BLUE])}</defs>", card_frame(W, H)]
    b.append(f'<text x="52" y="58" class="sans" font-size="26" font-weight="700" fill="{TEXT}">afm bench, in real time</text>')
    b.append(f'<text x="52" y="88" class="sans" font-size="15.5" fill="{DIM}">Apple M1 · macOS 27 · greedy sampling. Each bar runs at the speed it really took.</text>')
    # Seconds grid.
    for s in range(0, 5):
        gx = x0 + s * scale
        b.append(f'<path d="M{gx},{top - 22} V{top + row * len(BENCH) - 18}" stroke="{EDGE}" stroke-dasharray="2 5"/>')
        b.append(f'<text x="{gx}" y="{top - 30}" class="mono" font-size="12" fill="{FAINT}" text-anchor="middle">{s}s</text>')
    for i, (name, first, total, toks) in enumerate(BENCH):
        y = top + i * row
        b.append(f'<text x="{x0 - 22}" y="{y + 5}" class="sans" font-size="15" fill="{TEXT}" text-anchor="end">{name}</text>')
        b.append(f'<rect x="{x0}" y="{y - 12}" width="{total * scale:.1f}" height="24" rx="6" fill="{CARD}"/>')
        wait = tl.grow(start, start + first)
        b.append(f'<rect class="{wait}" x="{x0}" y="{y - 12}" width="{first * scale:.1f}" height="24" rx="6" fill="{ORANGE}" fill-opacity=".85"/>')
        if total - first > 0.005:
            gen = tl.grow(start + first, start + total)
            b.append(f'<rect class="{gen}" x="{x0 + first * scale:.1f}" y="{y - 12}" width="{(total - first) * scale:.1f}" height="24" rx="6" fill="url(#gen)"/>')
        done = tl.appear(start + total, ease=0.25)
        rate = f"{(toks - 1) / (total - first):.1f} tok/s" if toks >= 8 and total - first >= 0.05 else "too short to time"
        b.append(f'<g class="{done}"><text x="{x0 + total * scale + 14:.1f}" y="{y + 5}" class="mono" font-size="13.5" fill="{TEXT}">{toks} tokens</text>'
                 f'<text x="{x0 + total * scale + 14 + (len(str(toks)) + 8) * 8.2:.1f}" y="{y + 5}" class="mono" font-size="13.5" fill="{DIM}">· {rate}</text></g>')
    # Legend and summary.
    ly = H - 44
    b.append(f'<rect x="52" y="{ly - 12}" width="16" height="16" rx="4" fill="{ORANGE}"/><text x="76" y="{ly + 1}" class="sans" font-size="14" fill="{DIM}">waiting for the first token</text>')
    b.append(f'<rect x="290" y="{ly - 12}" width="16" height="16" rx="4" fill="url(#gen)"/><text x="314" y="{ly + 1}" class="sans" font-size="14" fill="{DIM}">generating</text>')
    summary = tl.appear(start + longest + 0.3, ease=0.3)
    b.append(f'<g class="{summary}"><text x="{W - 52}" y="{ly + 1}" class="sans" font-size="16" font-weight="600" fill="url(#g)" text-anchor="end">'
             f'median first token {ttft:.2f}s · decode speed {speed:.1f} tok/s</text></g>')
    return svg(W, H, "\n".join(b), tl.css(), "afm bench",
               f"Five benchmark tasks drawn at their real speed on an Apple M1: about half a second to the first token, then {speed:.0f} tokens per second.")


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in [("hero", hero), ("terminal", terminal), ("prose-to-json", prose_to_json), ("bench", bench)]:
        path = os.path.join(OUT, f"{name}.svg")
        with open(path, "w") as f:
            f.write(fn())
        print(f"{os.path.relpath(path)}  {os.path.getsize(path) // 1024} KB")
