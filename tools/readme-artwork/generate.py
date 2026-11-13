"""Zag Store README artwork. One source, light and dark output.

Palette and type follow zagstore.app's Refraction tokens (tokens.css).
Usage: python3 -I gen.py <icon-light.jpg> <icon-dark.jpg> <out-dir>
"""
import base64
import sys
from pathlib import Path
from xml.sax.saxutils import escape

ICON_LIGHT, ICON_DARK, OUT = sys.argv[1], sys.argv[2], Path(sys.argv[3])

FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', 'Helvetica Neue', Roboto, Arial, sans-serif"
MONO = "ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace"

THEMES = {
    "dark": dict(
        bg1="#05060c", bg2="#0d1020", text="#f3f5fb", text2="#a9b0c6", text3="#7f879f",
        glass="#ffffff", glass_o=0.055, glass_o2=0.09, border="#ffffff", border_o=0.12,
        s1="#13d5ed", s2="#4777f8", s3="#bc44e5", hs1="#5ff0ff", hs2="#8ea3ff", hs3="#d36cf2",
        atmo_a=0.30, atmo_b=0.26, atmo_c=0.22, grid="#8090c0", grid_o=0.07,
        live="#35cba5", shadow=0.55, icon=ICON_DARK, edge="#ffffff", edge_o=0.16,
    ),
    "light": dict(
        bg1="#f7f9fd", bg2="#eef2f9", text="#0f1729", text2="#4a5670", text3="#5d6782",
        glass="#ffffff", glass_o=0.70, glass_o2=0.86, border="#1e305a", border_o=0.11,
        s1="#0891c9", s2="#3a5ce8", s3="#b02fd9", hs1="#0891c9", hs2="#3a5ce8", hs3="#b02fd9",
        atmo_a=0.20, atmo_b=0.15, atmo_c=0.12, grid="#34508c", grid_o=0.06,
        live="#0f9a7a", shadow=0.12, icon=ICON_LIGHT, edge="#ffffff", edge_o=0.95,
    ),
}


def e(s):
    return escape(s, {'"': "&quot;"})


def icon_href(path):
    return "data:image/jpeg;base64," + base64.b64encode(Path(path).read_bytes()).decode()


def defs(t, w, h, extra=""):
    return f"""<defs>
<linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{t['bg1']}"/><stop offset="1" stop-color="{t['bg2']}"/></linearGradient>
<linearGradient id="spec" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="{t['s1']}"/><stop offset=".5" stop-color="{t['s2']}"/><stop offset="1" stop-color="{t['s3']}"/></linearGradient>
<linearGradient id="specText" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="{t['hs1']}"/><stop offset=".5" stop-color="{t['hs2']}"/><stop offset="1" stop-color="{t['hs3']}"/></linearGradient>
<radialGradient id="atA"><stop offset="0" stop-color="{t['s1']}" stop-opacity="{t['atmo_a']}"/><stop offset="1" stop-color="{t['s1']}" stop-opacity="0"/></radialGradient>
<radialGradient id="atB"><stop offset="0" stop-color="{t['s3']}" stop-opacity="{t['atmo_b']}"/><stop offset="1" stop-color="{t['s3']}" stop-opacity="0"/></radialGradient>
<radialGradient id="atC"><stop offset="0" stop-color="{t['s2']}" stop-opacity="{t['atmo_c']}"/><stop offset="1" stop-color="{t['s2']}" stop-opacity="0"/></radialGradient>
<linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{t['edge']}" stop-opacity="{t['edge_o']}"/><stop offset=".5" stop-color="{t['edge']}" stop-opacity="0"/></linearGradient>
<filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="18"/></filter>
<filter id="lift" x="-40%" y="-60%" width="180%" height="260%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#0a1440" flood-opacity="{t['shadow']}"/></filter>
<clipPath id="frame"><rect width="{w}" height="{h}" rx="32"/></clipPath>
{extra}
</defs>"""


STYLE = """<style>
text{font-family:%s}
.mono{font-family:%s}
@keyframes drift{0%%{transform:translate(0,0)}50%%{transform:translate(40px,-24px)}100%%{transform:translate(0,0)}}
@keyframes spin{to{transform:rotate(360deg)}}
@keyframes pulse{0%%,100%%{opacity:.55}50%%{opacity:1}}
@keyframes flow{to{stroke-dashoffset:-48}}
.drift{animation:drift 14s ease-in-out infinite}
.drift2{animation:drift 18s ease-in-out infinite reverse}
.spin{transform-box:fill-box;transform-origin:center;animation:spin 60s linear infinite}
.spin2{transform-box:fill-box;transform-origin:center;animation:spin 90s linear infinite reverse}
.pulse{animation:pulse 3.2s ease-in-out infinite}
.flow{stroke-dasharray:10 14;animation:flow 2.4s linear infinite}
@media (prefers-reduced-motion:reduce){.drift,.drift2,.spin,.spin2,.pulse,.flow{animation:none}}
</style>""" % (FONT, MONO)


def svg(w, h, label, body, t, extra_defs=""):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}" role="img" aria-label="{e(label)}">\n'
        f"<title>{e(label)}</title>\n{STYLE}\n{defs(t, w, h, extra_defs)}\n"
        f'<g clip-path="url(#frame)">\n<rect width="{w}" height="{h}" fill="url(#bg)"/>\n{body}\n</g>\n'
        f'<rect x=".5" y=".5" width="{w-1}" height="{h-1}" rx="31.5" fill="none" stroke="{t["border"]}" stroke-opacity="{t["border_o"]}"/>\n</svg>\n'
    )


def atmosphere(w, h, spots):
    out = []
    for i, (cx, cy, rx, ry, g) in enumerate(spots):
        cls = "drift" if i % 2 == 0 else "drift2"
        out.append(f'<g class="{cls}"><ellipse cx="{cx}" cy="{cy}" rx="{rx}" ry="{ry}" fill="url(#{g})"/></g>')
    return "\n".join(out)


def grid(t, x0, x1, y0, y1, step=64):
    lines = []
    x = x0
    while x <= x1:
        lines.append(f'<path d="M{x} {y0}V{y1}"/>')
        x += step
    y = y0
    while y <= y1:
        lines.append(f'<path d="M{x0} {y}H{x1}"/>')
        y += step
    return f'<g stroke="{t["grid"]}" stroke-opacity="{t["grid_o"]}" fill="none">{"".join(lines)}</g>'


def glass(t, x, y, w, h, r=24, strong=False, lift=True, solid=False):
    o = t["glass_o2"] if strong else t["glass_o"]
    f = ' filter="url(#lift)"' if lift else ""
    base = f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{t["bg2"]}" fill-opacity=".82"/>' if solid else ""
    return base + (
        f'<g{f}><rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{t["glass"]}" fill-opacity="{o}"/></g>'
        f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="url(#sheen)"/>'
        f'<rect x="{x+.5}" y="{y+.5}" width="{w-1}" height="{h-1}" rx="{r-.5}" fill="none" stroke="{t["border"]}" stroke-opacity="{t["border_o"]}"/>'
    )


def text(x, y, s, size, fill, weight=400, anchor="start", spacing=0, cls="", opacity=None):
    sp = f' letter-spacing="{spacing}"' if spacing else ""
    c = f' class="{cls}"' if cls else ""
    o = f' fill-opacity="{opacity}"' if opacity is not None else ""
    return f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{fill}" text-anchor="{anchor}"{sp}{c}{o}>{e(s)}</text>'


def lines(x, y, rows, size, fill, lh=1.38, weight=400):
    return "".join(text(x, y + i * size * lh, r, size, fill, weight) for i, r in enumerate(rows))


def pill(t, x, y, label, size=24, dot=None):
    w = int(len(label) * size * 0.5) + (64 if dot else 50)
    h = size + 26
    out = glass(t, x, y, w, h, r=h / 2, strong=True, lift=False)
    tx = x + 24
    if dot:
        out += f'<circle cx="{x+26}" cy="{y+h/2}" r="6" fill="{dot}" class="pulse"/>'
        tx = x + 42
    out += text(tx, y + h / 2 + size * 0.36, label, size, t["text"], 600)
    return out, w


# ---------------------------------------------------------------- icons (24-unit line glyphs)
def glyph(name, x, y, s, stroke="url(#spec)", width=1.8):
    k = s / 24
    paths = {
        "safari": '<circle cx="12" cy="12" r="9.5"/><path d="M15.8 8.2 13.4 13.4 8.2 15.8 10.6 10.6Z"/>',
        "cert": '<rect x="3.5" y="4" width="17" height="12.5" rx="2.2"/><path d="M7.5 8.5h9M7.5 12h5"/><circle cx="16" cy="16.5" r="2.6"/><path d="M14.6 18.6 14 21.5l2-1 2 1-.6-2.9"/>',
        "shield": '<path d="M12 3 19.5 6v5.5c0 4.6-3.2 8.3-7.5 9.5-4.3-1.2-7.5-4.9-7.5-9.5V6Z"/><path d="m8.7 12 2.3 2.3 4.4-4.6"/>',
        "home": '<rect x="5" y="2.5" width="14" height="19" rx="3"/><rect x="8" y="6.5" width="3.2" height="3.2" rx=".9"/><rect x="12.8" y="6.5" width="3.2" height="3.2" rx=".9"/><rect x="8" y="11.3" width="3.2" height="3.2" rx=".9"/><path d="M10.5 18.5h3"/>',
        "link": '<path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1.2 1.2"/><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1.2-1.2"/>',
        "signal": '<path d="M4 19v-2.5M9 19v-6M14 19V9.5M19 19V5"/>',
        "wifi": '<path d="M3.5 9.5a12 12 0 0 1 17 0M6.6 12.7a7.6 7.6 0 0 1 10.8 0M9.6 15.8a3.3 3.3 0 0 1 4.8 0"/><circle cx="12" cy="18.6" r=".9"/>',
        "lock": '<rect x="5" y="10.5" width="14" height="10" rx="2.4"/><path d="M8.2 10.5V7.8a3.8 3.8 0 0 1 7.6 0v2.7"/>',
        "key": '<circle cx="8" cy="12" r="4"/><path d="M12 12h9M18 12v3M15.5 12v2.2"/>',
        "check": '<circle cx="12" cy="12" r="9.5"/><path d="m8 12.3 2.7 2.7 5.3-5.6"/>',
        "phone2": '<rect x="7.5" y="3" width="9" height="18" rx="2.4"/><path d="M11 6h2"/>',
        "cable": '<path d="M7 3v5M11 3v5M5.5 8h7v3a3.5 3.5 0 0 1-7 0Z"/><path d="M9 14.5V17a4 4 0 0 0 8 0V9"/>',
        "laptop": '<rect x="4.5" y="5" width="15" height="10" rx="1.6"/><path d="M2.5 18.5h19"/>',
        "spark": '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.6 2.6M15.4 15.4 18 18M18 6l-2.6 2.6M8.6 15.4 6 18"/>',
        "update": '<path d="M19.5 12a7.5 7.5 0 1 1-2.2-5.3"/><path d="M19.8 4.5v4h-4"/><path d="M12 8.5V12l2.5 1.6"/>',
        "chart": '<path d="M4 20h16"/><rect x="5.5" y="12" width="3" height="6" rx=".8"/><rect x="10.5" y="8" width="3" height="10" rx=".8"/><rect x="15.5" y="4.5" width="3" height="13.5" rx=".8"/>',
        "globe": '<circle cx="12" cy="12" r="9.5"/><path d="M2.5 12h19M12 2.5c2.6 2.8 3.8 6 3.8 9.5S14.6 18.7 12 21.5C9.4 18.7 8.2 15.5 8.2 12S9.4 5.3 12 2.5Z"/>',
        "cpu": '<rect x="6" y="6" width="12" height="12" rx="2"/><rect x="9.5" y="9.5" width="5" height="5" rx="1"/><path d="M9 3v3M15 3v3M9 18v3M15 18v3M3 9h3M3 15h3M18 9h3M18 15h3"/>',
    }
    return (
        f'<g transform="translate({x} {y}) scale({k})" fill="none" stroke="{stroke}" stroke-width="{width}" '
        f'stroke-linecap="round" stroke-linejoin="round">{paths[name]}</g>'
    )


def strike(x, y, s, t):
    return f'<path d="M{x+2} {y+2} L{x+s-2} {y+s-2}" stroke="{t["s3"]}" stroke-width="3.2" stroke-linecap="round"/>'


# ---------------------------------------------------------------- hero
def hero(t):
    W, H = 1600, 800
    href = icon_href(t["icon"])
    extra = f"""<clipPath id="ic"><rect x="1062" y="252" width="296" height="296" rx="68"/></clipPath>
<radialGradient id="halo"><stop offset="0" stop-color="{t['s2']}" stop-opacity=".55"/><stop offset=".55" stop-color="{t['s3']}" stop-opacity=".16"/><stop offset="1" stop-color="{t['s3']}" stop-opacity="0"/></radialGradient>
<linearGradient id="orb" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{t['s1']}"/><stop offset=".5" stop-color="{t['s2']}" stop-opacity=".25"/><stop offset="1" stop-color="{t['s3']}"/></linearGradient>"""
    b = [atmosphere(W, H, [(1220, 360, 520, 420, "atC"), (1420, 700, 360, 260, "atB"), (260, 40, 520, 300, "atA"), (760, 820, 420, 200, "atB")])]
    b.append(grid(t, 832, 1600, 0, 800))
    # orbit system
    b.append(f'<ellipse cx="1210" cy="400" rx="330" ry="330" fill="url(#halo)"/>')
    b.append(f'<g class="spin"><circle cx="1210" cy="400" r="262" fill="none" stroke="url(#orb)" stroke-width="2" stroke-dasharray="2 10" stroke-linecap="round"/></g>')
    b.append(f'<g class="spin2"><path d="M948 400a262 262 0 0 1 120-220" fill="none" stroke="url(#spec)" stroke-width="3" stroke-linecap="round"/><circle cx="1068" cy="180" r="6" fill="{t["s1"]}"/></g>')
    b.append(f'<g class="spin"><path d="M1530 470a330 330 0 0 1-210 250" fill="none" stroke="url(#spec)" stroke-width="2.4" stroke-linecap="round" opacity=".8"/><circle cx="1320" cy="720" r="5" fill="{t["s3"]}"/></g>')
    b.append(f'<circle cx="1210" cy="400" r="330" fill="none" stroke="{t["border"]}" stroke-opacity="{t["border_o"]}"/>')
    # icon
    b.append(f'<g filter="url(#lift)"><rect x="1062" y="252" width="296" height="296" rx="68" fill="{t["bg1"]}"/></g>')
    b.append(f'<image href="{href}" x="1062" y="252" width="296" height="296" clip-path="url(#ic)" preserveAspectRatio="xMidYMid slice"/>')
    b.append(f'<rect x="1062.5" y="252.5" width="295" height="295" rx="67.5" fill="none" stroke="{t["edge"]}" stroke-opacity=".35"/>')
    # floating chips
    b.append(glass(t, 862, 168, 270, 64, r=32, strong=True, solid=True))
    b.append(glyph("lock", 884, 186, 28))
    b.append(text(924, 210, "zagstore.app", 24, t["text"], 600))
    b.append(glass(t, 1264, 590, 296, 64, r=32, strong=True, solid=True))
    b.append(f'<circle cx="1292" cy="622" r="7" fill="{t["live"]}" class="pulse"/>')
    b.append(text(1310, 631, "Paired on this iPhone", 23, t["text"], 600))
    b.append(glass(t, 900, 598, 236, 64, r=32, strong=True, solid=True))
    b.append(glyph("signal", 920, 615, 30))
    b.append(text(960, 638, "Mobile Data", 23, t["text"], 600))
    # copy
    b.append(text(96, 170, "ZAG STORE  ·  iPHONE AND iPAD  ·  PUBLIC BETA", 21, t["text3"], 600, spacing=4))
    b.append(text(92, 300, "Discover more.", 104, t["text"], 700, spacing=-3))
    b.append(text(92, 418, "Make it yours.", 104, "url(#specText)", 700, spacing=-3))
    b.append(lines(96, 498, ["Install from Safari. Pair on the device.", "Install apps over Wi-Fi or mobile data."], 32, t["text2"], 1.42))
    x = 96
    for label in ("Safari install", "No second device", "No cable"):
        p, w = pill(t, x, 618, label, 24)
        b.append(p)
        x += w + 16
    b.append(f'<rect x="96" y="716" width="520" height="2" rx="1" fill="url(#spec)" opacity=".75"/>')
    b.append(text(96, 754, "Your certificate. Your device. Built on Feather, rebuilt as Zag Store.", 20, t["text3"], 500))
    return svg(W, H, "Zag Store. Discover more. Make it yours. Install from Safari, pair on the device, install apps over Wi-Fi or mobile data. No second device, no cable.", "\n".join(b), t, extra)


# ---------------------------------------------------------------- chapter banners
CHAPTERS = [
    ("01", "A new identity", "From Feather's foundation to a visual language of its own."),
    ("02", "Reimagining the iOS experience", "Liquid Glass, a dock you arrange, discovery that feels native."),
    ("03", "Installation, unobstructed", "Safari install. No second device. No cable. Pairing on the device."),
    ("04", "Engineering beneath the surface", "Isolated signing, verified delivery, signed update metadata."),
    ("05", "Beyond the app", "A website, a catalogue and installation insights, built as one product."),
    ("06", "The road ahead", "What is in testing, what is planned, and what is not promised yet."),
]


def chapter(t, num, title, sub):
    W, H = 1600, 240
    b = [atmosphere(W, H, [(160, 120, 360, 200, "atA"), (1500, 200, 420, 200, "atB")])]
    b.append(f'<text x="72" y="178" font-size="168" font-weight="800" fill="none" stroke="url(#spec)" stroke-width="2.4" letter-spacing="-6">{num}</text>')
    b.append(f'<rect x="340" y="62" width="4" height="116" rx="2" fill="url(#spec)"/>')
    b.append(text(380, 112, title, 60, t["text"], 700, spacing=-1.5))
    b.append(text(382, 162, sub, 27, t["text2"], 500))
    return svg(W, H, f"Chapter {num}: {title}. {sub}", "\n".join(b), t)


# ---------------------------------------------------------------- journey (Safari install)
def journey(t):
    W, H = 1600, 640
    b = [atmosphere(W, H, [(200, 60, 480, 260, "atA"), (1440, 600, 480, 260, "atB"), (800, 320, 520, 260, "atC")])]
    b.append(text(72, 92, "STEP ONE  ·  GET ZAG STORE", 21, t["text3"], 600, spacing=4))
    b.append(text(70, 156, "From Safari to your Home Screen.", 54, t["text"], 700, spacing=-1.2))
    cards = [
        ("safari", "01", "Open zagstore.app", ["In Safari, on the iPhone", "or iPad you install on.", "Nothing else to set up."]),
        ("cert", "02", "Your certificate", ["Your .p12, its password", "and a provisioning profile", "that includes this device."]),
        ("shield", "03", "Isolated signing", ["A dedicated service signs", "this copy, then delivers it", "by a private, expiring link."]),
        ("home", "04", "iOS installs it", ["Once iOS has verified the", "signature and that your", "profile covers the device."]),
    ]
    x0, cw, gap, y = 72, 350, 24, 214
    for i, (g, n, title, desc) in enumerate(cards):
        x = x0 + i * (cw + gap)
        b.append(glass(t, x, y, cw, 312, r=28))
        b.append(glyph(g, x + 30, y + 30, 46))
        b.append(text(x + cw - 30, y + 62, n, 26, "url(#specText)", 700, "end"))
        b.append(text(x + 30, y + 148, title, 30, t["text"], 700))
        b.append(lines(x + 30, y + 196, desc, 22, t["text2"], 1.42))
    # footer: removed obstacles + what stays
    fx = 72
    for g, label in (("laptop", "No computer"), ("phone2", "No second device"), ("cable", "No cable")):
        b.append(glyph(g, fx, 562, 30, stroke=t["text2"], width=1.7))
        b.append(strike(fx, 562, 30, t))
        b.append(text(fx + 42, 585, label, 23, t["text"], 600))
        fx += 42 + int(len(label) * 23 * 0.56) + 40
    b.append(text(1528, 585, "Still required: your own signing certificate and profile.", 21, t["text3"], 500, "end"))
    return svg(W, H, "Step one, get Zag Store: open zagstore.app in Safari, add your own certificate and provisioning profile, Zag Store's isolated signing service signs your copy and delivers it by a private expiring link, and iOS installs it after verifying the signature and profile. No computer, no second device, no cable. Your own signing certificate and profile are still required.", "\n".join(b), t)


# ---------------------------------------------------------------- pairing (install apps)
def pairing(t):
    W, H = 1600, 760
    b = [atmosphere(W, H, [(300, 420, 420, 420, "atC"), (1450, 120, 420, 240, "atA"), (1300, 760, 420, 220, "atB")])]
    b.append(text(72, 92, "STEP TWO  ·  INSTALL APPS", 21, t["text3"], 600, spacing=4))
    b.append(text(70, 156, "Pair once. Install from the device itself.", 54, t["text"], 700, spacing=-1.2))
    # phone
    px, py, pw, ph = 96, 200, 360, 540
    b.append(f'<g filter="url(#lift)"><rect x="{px}" y="{py}" width="{pw}" height="{ph}" rx="54" fill="{t["bg2"]}"/></g>')
    b.append(f'<rect x="{px+1}" y="{py+1}" width="{pw-2}" height="{ph-2}" rx="53" fill="none" stroke="url(#spec)" stroke-width="2.5"/>')
    b.append(f'<rect x="{px+120}" y="{py+18}" width="90" height="24" rx="12" fill="{t["text"]}" fill-opacity=".85"/>')
    layers = [("Zag Store", "Pair · sign · install", "spark"), ("LocalDevVPN", "On-device loopback", "link"), ("iOS device services", "RemotePairing · installd", "cpu")]
    ly = py + 76
    for i, (name, sub, g) in enumerate(layers):
        b.append(glass(t, px + 24, ly, pw - 48, 104, r=22, strong=True, lift=False))
        b.append(glyph(g, px + 44, ly + 32, 38))
        b.append(text(px + 98, ly + 48, name, 22, t["text"], 700))
        b.append(text(px + 98, ly + 78, sub, 18, t["text2"], 500))
        if i < 2:
            b.append(f'<path d="M{px+pw/2} {ly+110}v24" stroke="url(#spec)" stroke-width="2.6" stroke-linecap="round" class="flow"/>')
        ly += 140
    b.append(text(px + pw / 2, py + ph - 26, "Everything stays on one device", 18, t["text3"], 600, "middle"))
    # right column facts
    rows = [
        ("key", "Pairs with itself", ["A pairing code shown on this device. No computer and no", "pairing file on iOS 17 and later. Unpair at any time."]),
        ("signal", "Wi-Fi or mobile data", ["On mobile data, an Apple Shortcut switches Mobile Data off", "for the install and back on. You approve it first."]),
        ("lock", "Credentials stay on the device", ["Pairing credentials are stored locally and reused.", "Diagnostics never include pairing records or keys."]),
        ("check", "What is still required", ["LocalDevVPN connected, a signing certificate, and a", "provisioning profile that includes this device."]),
    ]
    ry = 206
    for g, title, desc in rows:
        b.append(glass(t, 520, ry, 1008, 120, r=24))
        b.append(glyph(g, 548, ry + 38, 44))
        b.append(text(618, ry + 44, title, 27, t["text"], 700))
        b.append(lines(618, ry + 78, desc, 21, t["text2"], 1.36))
        ry += 132
    return svg(W, H, "Step two, install apps: pair Zag Store with its own device using a pairing code, with no computer or pairing file on iOS 17 and later. Install over Wi-Fi or mobile data, where an Apple Shortcut turns Mobile Data off for the install. Pairing credentials stay on the device. LocalDevVPN, a signing certificate and a provisioning profile that includes the device are still required.", "\n".join(b), t)


# ---------------------------------------------------------------- evolution metrics
def evolution(t):
    W, H = 1600, 700
    b = [atmosphere(W, H, [(240, 80, 520, 260, "atA"), (1400, 640, 520, 280, "atB")])]
    b.append(text(72, 92, "FROM FEATHER 2.9.0 TO ZAG STORE", 21, t["text3"], 600, spacing=4))
    b.append(text(70, 156, "Five times the app it started as.", 54, t["text"], 700, spacing=-1.2))
    # bars
    maxw = 1080
    b.append(text(72, 236, "Swift source in the app target", 24, t["text2"], 600))
    for i, (label, val, fill) in enumerate((("Feather 2.9.0, at the fork", 10224, t["text3"]), ("Zag Store today", 50332, "url(#spec)"))):
        y = 266 + i * 74
        w = maxw * val / 50332
        b.append(f'<rect x="72" y="{y}" width="{maxw}" height="44" rx="22" fill="{t["glass"]}" fill-opacity="{t["glass_o"]}"/>')
        b.append(f'<rect x="72" y="{y}" width="{w:.0f}" height="44" rx="22" fill="{fill}" fill-opacity="{1 if i else .55}"/>')
        b.append(text(72 + maxw + 24, y + 31, f"{val:,} lines", 26, t["text"], 700))
        b.append(text(92 if i else 72 + w + 18, y + 30, label, 21, "#ffffff" if i else t["text2"], 600))
    stats = [("2,071", "commits since the fork"), ("74", "new Swift source files"), ("46", "Feather files reworked"), ("2,273", "lines of Rust pairing core"), ("40", "host test suites")]
    sx, sw, sg = 72, 276, 18
    for i, (n, label) in enumerate(stats):
        x = sx + i * (sw + sg)
        b.append(glass(t, x, 446, sw, 150, r=26))
        b.append(text(x + 26, 522, n, 54, "url(#specText)", 800, spacing=-1.5))
        b.append(text(x + 28, 564, label, 21, t["text2"], 600))
    b.append(text(72, 650, "Measured with git from fork point 4db3efff (Feather v2.9.0, 4 July 2026) to Zag Store main 9a3995e4. Swift counted under Feather/.", 18, t["text3"], 500))
    return svg(W, H, "From Feather 2.9.0 to Zag Store: Swift source grew from 10,224 lines at the fork to 50,332 lines today. 2,071 commits since the fork, 74 new Swift source files, 46 Feather files reworked, 2,273 lines of Rust pairing core and 40 host test suites.", "\n".join(b), t)


# ---------------------------------------------------------------- ecosystem
def ecosystem(t):
    W, H = 1600, 800
    b = [atmosphere(W, H, [(800, 420, 620, 380, "atC"), (180, 120, 420, 240, "atA"), (1460, 720, 420, 240, "atB")])]
    b.append(text(72, 92, "THE ZAG STORE ECOSYSTEM", 21, t["text3"], 600, spacing=4))
    b.append(text(70, 156, "One product, well beyond the app.", 54, t["text"], 700, spacing=-1.2))
    nodes = {
        "app": (72, 330, 400, 236, "home", "Zag Store for iOS", ["Discover, sign, install", "and update on the device"], "This repository"),
        "web": (600, 214, 400, 200, "globe", "zagstore.app", ["Catalogue, repositories", "and the Safari installer"], "Website"),
        "sign": (600, 470, 400, 200, "shield", "Signing service", ["Gateway and isolated", "workers; your certificate"], "Private service"),
        "rel": (1128, 214, 400, 200, "update", "Release channels", ["Stable, Beta and Nightly;", "SHA-256 and Ed25519"], "Public metadata"),
        "ins": (1128, 470, 400, 200, "chart", "Installation insights", ["Attribution and first", "launch, shown in totals"], "Server-side"),
    }
    # connectors (drawn first)
    def mid(n, side):
        x, y, w, h = nodes[n][:4]
        return {"r": (x + w, y + h / 2), "l": (x, y + h / 2), "t": (x + w / 2, y), "b": (x + w / 2, y + h)}[side]
    paths = [
        "M472 448C536 448 536 314 600 314",   # app -> website
        "M472 448C536 448 536 570 600 570",   # app <- signing service
        "M800 414V470",                       # website -> signing service
        "M472 448H1040C1084 448 1084 314 1128 314",  # app <-> release channels
        "M1040 448C1084 448 1084 570 1128 570",      # app -> installation insights
    ]
    for d in paths:
        b.append(f'<path d="{d}" fill="none" stroke="url(#spec)" stroke-width="2.4" stroke-opacity=".85" class="flow"/>')
    for key, (x, y, w, h, g, title, desc, tag) in nodes.items():
        b.append(glass(t, x, y, w, h, r=28, strong=key == "app"))
        b.append(glyph(g, x + 28, y + 30, 44))
        tw = int(len(tag) * 17 * 0.6) + 28
        b.append(f'<rect x="{x+w-28-tw}" y="{y+34}" width="{tw}" height="32" rx="16" fill="url(#spec)" fill-opacity="{.95 if key == "app" else .14}"/>')
        b.append(text(x + w - 28 - tw / 2, y + 56, tag, 17, "#ffffff" if key == "app" else t["text"], 700, "middle"))
        b.append(text(x + 28, y + 122, title, 30, t["text"], 700))
        b.append(lines(x + 28, y + (162 if key == "app" else 160), desc, 21, t["text2"], 1.38))
    b.append(text(72, 742, "Server components run on Zag Store's infrastructure and are not part of this repository. Only the iOS app's source is published here.", 19, t["text3"], 500))
    return svg(W, H, "The Zag Store ecosystem: the iOS app in this repository; zagstore.app with the catalogue, repositories and Safari installer; a private signing service with a gateway and isolated workers; public release channels with SHA-256 and Ed25519 signed metadata; and server-side installation insights shown in totals. Server components are not part of this repository.", "\n".join(b), t)


OUT.mkdir(parents=True, exist_ok=True)
for name, t in THEMES.items():
    (OUT / f"hero-{name}.svg").write_text(hero(t))
    (OUT / f"journey-{name}.svg").write_text(journey(t))
    (OUT / f"pairing-{name}.svg").write_text(pairing(t))
    (OUT / f"evolution-{name}.svg").write_text(evolution(t))
    (OUT / f"ecosystem-{name}.svg").write_text(ecosystem(t))
    for num, title, sub in CHAPTERS:
        (OUT / f"chapter-{num}-{name}.svg").write_text(chapter(t, num, title, sub))
print("ok")
