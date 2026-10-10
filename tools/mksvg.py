#!/usr/bin/env python3
"""ANSI render of agentline -> docs/preview.svg (terminal-window look).

  mksvg.py <ansi-file> <out.svg> <columns> [window-title] [aria-label]

The agent column (entries after a run of 3+ spaces, starting with the robot
glyph) is drawn right-aligned at the window edge, so it lines up whatever
width the viewer's font gives the emoji.
"""
import html, re, sys

src, dst, cols = sys.argv[1], sys.argv[2], int(sys.argv[3])
# Optional window title and aria-label, so one generator serves the main
# line and the subagent rows without either picture lying about itself.
title = sys.argv[4] if len(sys.argv) > 4 else 'agentline — Claude Code'
alt = sys.argv[5] if len(sys.argv) > 5 else 'agentline status bar rendered in a terminal window'
raw = open(src, encoding='utf-8').read()
raw = re.sub(r'\x1b\]8;;[^\x07]*\x07', '', raw)
FONT = "SFMono-Regular, Menlo, Consolas, 'DejaVu Sans Mono', 'Noto Color Emoji', monospace"
DEF = '#c8ccd4'
ANSI = {30: '#5c6370', 31: '#ff6b6b', 32: '#5ef78d', 33: '#ffd75a', 34: '#6cb6ff', 35: '#e58cff',
        36: '#56d4dd', 37: DEF, 90: '#7d828f', 91: '#ff8080', 92: '#7dffa8', 93: '#ffe27a',
        94: '#8cc8ff', 95: '#f0a8ff', 96: '#7ee6ec', 97: '#ffffff'}
X256 = {208: '#ff8700', 166: '#d75f00', 214: '#ffaf00', 141: '#af87ff'}


def spans(line):
    out, fill, bold, dim = [], DEF, False, False
    pos = 0
    for m in re.finditer(r'\x1b\[([0-9;]*)m', line):
        if m.start() > pos:
            out.append((line[pos:m.start()], '#7d828f' if dim and fill == DEF else fill, bold))
        pos = m.end()
        codes = [int(c) for c in m.group(1).split(';') if c] or [0]
        i = 0
        while i < len(codes):
            c = codes[i]
            if c == 0:
                fill, bold, dim = DEF, False, False
            elif c == 1:
                bold = True
            elif c == 2:
                dim = True
            elif c == 38 and i + 1 < len(codes) and codes[i + 1] == 2:
                fill = '#%02x%02x%02x' % tuple(codes[i + 2:i + 5]); i += 4
            elif c == 38 and i + 1 < len(codes) and codes[i + 1] == 5:
                fill = X256.get(codes[i + 2], DEF); i += 2
            elif c in ANSI:
                fill = ANSI[c]
            i += 1
    if pos < len(line):
        out.append((line[pos:], '#7d828f' if dim and fill == DEF else fill, bold))
    return out


def tspans(parts):
    return ''.join('<tspan fill="%s"%s>%s</tspan>' % (f, ' font-weight="600"' if b else '', html.escape(t))
                   for t, f, b in parts if t)


lines = raw.split('\n')
cw = 7.83  # cell width at 13px
W = int(cols * cw + 44)
H = 40 + 24 * len(lines) + 22
o = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" width="%d" height="%d" role="img" '
     'aria-label="%s">' % (W, H, W, H, html.escape(alt, quote=True)),
     '<rect x="0.5" y="0.5" width="%d" height="%d" rx="10" fill="#15171e" stroke="#2c3040"/>' % (W - 1, H - 1),
     '<path d="M0.5 40 H%.1f" stroke="#2c3040"/>' % (W - 0.5),
     '<circle cx="24" cy="20" r="5.5" fill="#ff5f57"/>', '<circle cx="44" cy="20" r="5.5" fill="#febc2e"/>',
     '<circle cx="64" cy="20" r="5.5" fill="#28c840"/>',
     '<text x="%d" y="24" text-anchor="middle" font-family="%s" font-size="12" fill="#6f7484">%s</text>' % (W // 2, FONT, html.escape(title))]
for n, line in enumerate(lines):
    y = 70 + 24 * n
    parts = spans(line)
    plain = ''.join(t for t, _, _ in parts)
    m = re.search(r' {3,}(\U0001F916 .*)$', plain)
    right = []
    if m:
        cut = m.start()
        left, acc = [], 0
        for t, f, b in parts:
            if acc + len(t) <= cut:
                left.append((t, f, b))
            elif acc < cut:
                left.append((t[:cut - acc], f, b)); right.append((t[cut - acc:].lstrip(' '), f, b))
            else:
                right.append((t, f, b))
            acc += len(t)
        parts = left
    o.append('<text x="22" y="%d" xml:space="preserve" font-family="%s" font-size="13.0">%s</text>' % (y, FONT, tspans(parts)))
    if right:
        o.append('<text x="%d" y="%d" text-anchor="end" xml:space="preserve" font-family="%s" font-size="13.0">%s</text>'
                 % (W - 22, y, FONT, tspans(right)))
o.append('</svg>')
open(dst, 'w', encoding='utf-8').write('\n'.join(o) + '\n')
print('wrote', dst, W, 'x', H)
