#!/usr/bin/env python3
"""Generate every icon of one client from its two master SVGs.

    gen_icons.py <platform> <repo-root>          platform: web | android | desktop
    gen_icons.py <platform> <repo-root> --check  exit 1 if the committed icons are stale

Masters, in <platform>/branding/:
    logo.svg        the full-colour icon (a rounded square)
    logo-glyph.svg  the same mark as one flat shape, for places that tint it:
                    notifications, the tray, adaptive-icon foregrounds, masks

Edit those two files, run this, commit the result. The generated files are
COMMITTED into <platform>/overlay/, not produced at build time: a build machine
should not need a rasteriser, and a reviewer can see what shipped.

Why it exists at all: an audit found the clients still carried other projects'
marks -- Telegram's paper plane (desktop icons, the Android terms screen and
server picker), the upstream fork's own logo (web favicons, Android launcher and
notification icon). Renaming strings does nothing about an image.

Rendering: rsvg-convert or ImageMagick when installed, otherwise Chromium through
Playwright (Node). Everything after that is Pillow (pip install pillow).

Idempotent. The stamp file (<platform>/branding/.logo-stamp) holds a hash of both
masters; --check and the selftests compare it, so editing a master without
regenerating is caught instead of shipping the old mark.
"""
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

PLATFORMS = {}


# --------------------------------------------------------------------- masters
def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def inner(svg):
    """The elements of an SVG without its <svg> wrapper (defs included)."""
    m = re.search(r"<svg\b[^>]*>(.*)</svg>\s*$", svg, re.S)
    if not m:
        sys.exit("gen_icons: a master is not a single <svg> element")
    return m.group(1).strip()


class Masters:
    def __init__(self, branding):
        self.full = read(os.path.join(branding, "logo.svg"))
        self.glyph = read(os.path.join(branding, "logo-glyph.svg"))
        for name, text in (("logo.svg", self.full), ("logo-glyph.svg", self.glyph)):
            if "viewBox=\"0 0 512 512\"" not in text:
                sys.exit(f"gen_icons: {name} must use viewBox=\"0 0 512 512\" (the variants below place it by that box)")

    def stamp(self):
        h = hashlib.sha256()
        h.update(self.full.encode())
        h.update(b"\0")
        h.update(self.glyph.encode())
        return h.hexdigest()

    # -- variants, as SVG text ------------------------------------------------
    def square(self):
        """Full-bleed, square corners: for stores that round the icon themselves."""
        return re.sub(r'(<rect\b[^>]*?)\brx="\d+"', r'\1rx="0"', self.full, count=1)

    def palette(self, start, end):
        """The full icon with another gradient (the alternative launcher icons)."""
        stops = re.findall(r'stop-color="#[0-9A-Fa-f]{6}"', self.full)
        if len(stops) != 2:
            sys.exit("gen_icons: logo.svg must have exactly two gradient stops")
        t = self.full.replace(stops[0], f'stop-color="{start}"', 1).replace(stops[1], f'stop-color="{end}"', 1)
        return Masters._from(t, self.glyph)

    @staticmethod
    def _from(full, glyph):
        m = object.__new__(Masters)
        m.full, m.glyph = full, glyph
        return m

    def background(self, circle=False):
        """Only the gradient: the adaptive-icon background layer. Everything that
        is not the gradient rect or its defs is dropped, whatever the master draws on top."""
        t = re.sub(r'<path\b[^>]*/>', '', self.full)
        t = re.sub(r'(<rect\b[^>]*?)\brx="\d+"', r'\1rx="0"', t, count=1)
        if circle:
            return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">'
                    '<clipPath id="fc-round"><circle cx="256" cy="256" r="256"/></clipPath>'
                    f'<g clip-path="url(#fc-round)">{inner(t)}</g></svg>')
        return t

    def path_data(self):
        """The d= of the glyph's single path."""
        d = re.findall(r'\sd="([^"]+)"', self.glyph)
        if len(d) != 1:
            sys.exit("gen_icons: logo-glyph.svg must hold exactly one <path d=...>")
        return d[0]

    def subpaths(self):
        """The glyph's d= split at each closed subpath: [bubble, F]. For renderers
        that ignore fill-rule (Telegram's own SvgHelper): draw the bubble, then the
        F over it in the background colour, instead of relying on a hole."""
        parts = [x.strip() for x in re.split(r'(?<=[zZ])(?=M)', self.path_data()) if x.strip()]
        if len(parts) != 2:
            sys.exit("gen_icons: logo-glyph.svg is expected to be a bubble plus one cut-out letter (two subpaths)")
        return parts

    def gradient_colours(self):
        stops = re.findall(r'stop-color="(#[0-9A-Fa-f]{6})"', self.full)
        return stops[0], stops[-1]

    def tinted(self, colour):
        return re.sub(r'fill="#[0-9A-Fa-f]{3,8}"', f'fill="{colour}"', self.glyph)

    def circle(self):
        """The full icon clipped to a circle (round launcher icons)."""
        return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">'
                '<clipPath id="fc-round"><circle cx="256" cy="256" r="256"/></clipPath>'
                f'<g clip-path="url(#fc-round)">{inner(self.full)}</g></svg>')

    def placed(self, svg, w, h, frac, bg=None):
        """`svg` (a 512 box) centred in a w x h canvas, taking `frac` of the short side."""
        side = min(w, h) * frac
        k = side / 512.0
        x, y = (w - side) / 2, (h - side) / 2
        back = f'<rect width="{w}" height="{h}" fill="{bg}"/>' if bg else ""
        return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}">{back}'
                f'<g transform="translate({x:.3f} {y:.3f}) scale({k:.5f})">{inner(svg)}</g></svg>')


# -------------------------------------------------------------------- renderer
class Renderer:
    """Batch rasteriser: queue (svg, w, h) jobs, get PIL images back."""

    def __init__(self, repo):
        self.repo = repo
        self.jobs = []
        self.tool = self._find()

    def _find(self):
        for t in ("rsvg-convert", "magick", "inkscape"):
            if shutil.which(t):
                return t
        return "chromium"

    def add(self, svg, w, h):
        self.jobs.append((svg, int(w), int(h)))
        return len(self.jobs) - 1

    def run(self):
        from PIL import Image  # only rendering needs it; --check must work without Pillow
        out = [None] * len(self.jobs)
        tmp = tempfile.mkdtemp(prefix="fc-icons-")
        try:
            if self.tool == "chromium":
                self._chromium(tmp)
            else:
                self._cli(tmp)
            for i in range(len(self.jobs)):
                im = Image.open(os.path.join(tmp, f"{i}.png"))
                im.load()
                out[i] = im.convert("RGBA")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        return out

    def _cli(self, tmp):
        for i, (svg, w, h) in enumerate(self.jobs):
            src = os.path.join(tmp, f"{i}.svg")
            dst = os.path.join(tmp, f"{i}.png")
            with open(src, "w", encoding="utf-8") as fh:
                fh.write(svg)
            if self.tool == "rsvg-convert":
                cmd = ["rsvg-convert", "-w", str(w), "-h", str(h), "-o", dst, src]
            elif self.tool == "magick":
                cmd = ["magick", "-background", "none", "-density", "384", src, "-resize", f"{w}x{h}!", dst]
            else:
                cmd = ["inkscape", src, "-w", str(w), "-h", str(h), "-o", dst]
            subprocess.run(cmd, check=True)

    def _chromium(self, tmp):
        """Playwright is looked for next to the web client's dependencies, or
        wherever FREECHAT_PLAYWRIGHT_FROM points (a directory with node_modules)."""
        hint = os.environ.get("FREECHAT_PLAYWRIGHT_FROM", "")
        cands = [hint] if hint else []
        for d in ("web/upstream", "../freechat-web/web/upstream"):
            cands.append(os.path.join(self.repo, d))
        base = next((c for c in cands if c and os.path.isdir(os.path.join(c, "node_modules", "@playwright"))), None)
        if not base:
            sys.exit("gen_icons: no SVG renderer. Install rsvg-convert (librsvg2-bin) or ImageMagick,\n"
                     "  or point FREECHAT_PLAYWRIGHT_FROM at a directory whose node_modules has @playwright/test\n"
                     "  (freechat-web/web/upstream after ./scripts/build-web.sh install).")
        exe = os.environ.get("FREECHAT_CHROMIUM", "")
        if not exe:
            root = os.environ.get("PLAYWRIGHT_BROWSERS_PATH", "")
            for pat in ("chromium", "chromium-*/chrome-linux/chrome"):
                import glob
                hits = sorted(glob.glob(os.path.join(root, pat))) if root else []
                if hits:
                    exe = hits[-1]
                    break
        with open(os.path.join(tmp, "jobs.json"), "w", encoding="utf-8") as fh:
            json.dump(self.jobs, fh)
        js = r"""
const {createRequire} = require('node:module');
const req = createRequire(process.argv[2] + '/package.json');
const {chromium} = req('@playwright/test');
const fs = require('node:fs');
(async () => {
  const jobs = JSON.parse(fs.readFileSync(process.argv[3] + '/jobs.json', 'utf8'));
  const opts = {args: ['--no-sandbox']};
  if(process.argv[4]) opts.executablePath = process.argv[4];
  const browser = await chromium.launch(opts);
  for(let i = 0; i < jobs.length; ++i) {
    const [svg, w, h] = jobs[i];
    const page = await browser.newPage({viewport: {width: w, height: h}, deviceScaleFactor: 1});
    const el = svg.replace('<svg ', `<svg width="${w}" height="${h}" `);
    await page.setContent(`<html><body style="margin:0;background:transparent">${el}</body></html>`);
    await page.screenshot({path: process.argv[3] + '/' + i + '.png', omitBackground: true, clip: {x: 0, y: 0, width: w, height: h}});
    await page.close();
  }
  await browser.close();
})().catch((e) => { console.error(e); process.exit(1); });
"""
        with open(os.path.join(tmp, "render.cjs"), "w", encoding="utf-8") as fh:
            fh.write(js)
        subprocess.run(["node", os.path.join(tmp, "render.cjs"), base, tmp, exe], check=True)


# ---------------------------------------------------------------------- output
class Out:
    """Collects files for one run; writes them under <overlay>/<relative path>."""

    def __init__(self, overlay):
        self.overlay = overlay
        self.files = {}

    def png(self, rel, im):
        b = io.BytesIO()
        im.save(b, "PNG", optimize=True)
        self.files[rel] = b.getvalue()

    def webp(self, rel, im, lossless=True):
        b = io.BytesIO()
        im.save(b, "WEBP", lossless=lossless, quality=100)
        self.files[rel] = b.getvalue()

    def text(self, rel, s):
        self.files[rel] = s.encode("utf-8")

    def ico(self, rel, images):
        b = io.BytesIO()
        biggest = max(images, key=lambda i: i.width)
        biggest.save(b, "ICO", sizes=[(i.width, i.height) for i in images], append_images=[i for i in images if i is not biggest])
        self.files[rel] = b.getvalue()

    def write(self):
        for rel, data in sorted(self.files.items()):
            path = os.path.join(self.overlay, rel)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if os.path.isfile(path) and open(path, "rb").read() == data:
                continue
            with open(path, "wb") as fh:
                fh.write(data)
        return len(self.files)


# ------------------------------------------------------------------------- web
def build_web(m, r, out):
    """Sizes are those of the files upstream ships, so nothing that references
    them by size or name needs to change."""
    img = "public/assets/img/"
    jobs = {}

    def q(key, svg, w, h=None):
        jobs[key] = r.add(svg, w, h or w)

    for s in (36, 48, 72, 96, 144, 192, 256, 384, 512):
        q(f"{img}android-chrome-{s}x{s}.png", m.full, s)
    for s in (16, 32, 194):
        q(f"{img}favicon-{s}x{s}.png", m.full, s)
    for s in (192, 384, 512):
        q(f"{img}icon_square_{s}.png", m.full, s)
    q(f"{img}logo_512.png", m.full, 512)
    q(f"{img}logo_filled_rounded.png", m.full, 512)
    for n in ("apple-touch-icon.png", "apple-touch-icon-precomposed.png"):
        q(img + n, m.square(), 180)
    # Windows tiles: the mark on a transparent tile (browserconfig.xml sets the colour)
    for n, (w, h) in {"mstile-144x144.png": (144, 144), "mstile-150x150.png": (270, 270),
                      "mstile-310x150.png": (558, 270), "mstile-310x310.png": (558, 558),
                      "mstile-70x70.png": (128, 128)}.items():
        q(img + n, m.placed(m.full, w, h, 0.7), w, h)
    ico_sizes = {s: r.add(m.full, s, s) for s in (16, 32, 48)}
    dot = ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512"><g>' + inner(m.full) +
           '</g><circle cx="400" cy="112" r="96" fill="#E53935" stroke="#FFFFFF" stroke-width="24"/></svg>')
    unread = {s: r.add(dot, s, s) for s in (16, 32)}

    ims = r.run()
    for key, idx in jobs.items():
        out.png(key, ims[idx])
    out.ico(img + "favicon.ico", [ims[ico_sizes[s]] for s in (48, 32, 16)])
    out.ico(img + "favicon_unread.ico", [ims[unread[s]] for s in (32, 16)])

    out.text(img + "logo.svg", m.full)
    out.text(img + "logo_filled.svg", m.full)
    out.text(img + "logo_padded.svg", m.placed(m.full, 512, 512, 0.84))
    out.text(img + "logo_plain.svg", m.glyph)  # masked by the page, colour comes from CSS


PLATFORMS["web"] = {"build": build_web, "overlay": "web/overlay", "branding": "web/branding"}



# --------------------------------------------------------------------- android
# Alternative launcher icons Telegram lets the user pick (icon_2 .. icon_6). Same
# mark, other gradients, so the picker offers six distinct icons, not six copies.
ANDROID_PALETTES = {2: ("#F6A93B", "#E4572E"), 3: ("#2FB8F5", "#2D63E6"), 4: ("#2DC98B", "#0E8C6B"),
                    5: ("#EE63A7", "#8F4FE3"), 6: ("#434B61", "#1A1E2B")}


def _wordmark(text, height_units, font):
    """`text` as one SVG path (y down), height_units tall, plus its width. The
    outlines are copied out of the font, so nothing needs the font at run time."""
    from fontTools.ttLib import TTFont
    from fontTools.pens.svgPathPen import SVGPathPen
    from fontTools.pens.transformPen import TransformPen
    f = TTFont(font)
    gs, cmap, upm = f.getGlyphSet(), f.getBestCmap(), f["head"].unitsPerEm
    asc = getattr(f["OS/2"], "sCapHeight", 0) or int(upm * 0.73)
    k = height_units / float(asc)
    pen = SVGPathPen(gs, ntos=lambda v: ("%.2f" % v).rstrip("0").rstrip("."))
    x = 0
    for ch in text:
        g = cmap[ord(ch)]
        gs[g].draw(TransformPen(pen, (k, 0, 0, -k, x * k, height_units)))
        x += gs[g].width
    return pen.getCommands(), x * k


def _wordmark_font():
    for c in (os.environ.get("FREECHAT_WORDMARK_FONT", ""),
              "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
              "/Library/Fonts/Arial Bold.ttf", "C:/Windows/Fonts/arialbd.ttf"):
        if c and os.path.isfile(c):
            return c
    sys.exit("gen_icons: no bold font for the wordmark. Set FREECHAT_WORDMARK_FONT to a .ttf file\n"
             "  you may embed (DejaVu Sans Bold and Liberation Sans Bold are fine).")


def _sub_gradient(xml, start, end):
    xml = re.sub(r'android:startColor="#[0-9A-Fa-f]{6,8}"', f'android:startColor="{start}"', xml)
    return re.sub(r'android:endColor="#[0-9A-Fa-f]{6,8}"', f'android:endColor="{end}"', xml)


def _lottie(m):
    """A small looping mark for the QR screen: the icon, breathing. Built from
    rounded rectangles, which every Lottie renderer draws, rather than from the
    glyph's curves."""
    c0, c1 = m.gradient_colours()
    def rgb(h):
        return [int(h[i:i + 2], 16) / 255.0 for i in (1, 3, 5)] + [1]
    def rc(pos, size, r, col, name):
        return {"ty": "gr", "nm": name, "it": [
            {"ty": "rc", "p": {"a": 0, "k": pos}, "s": {"a": 0, "k": size}, "r": {"a": 0, "k": r}},
            {"ty": "fl", "c": {"a": 0, "k": col}, "o": {"a": 0, "k": 100}},
            {"ty": "tr", "p": {"a": 0, "k": [0, 0]}, "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]},
             "r": {"a": 0, "k": 0}, "o": {"a": 0, "k": 100}}]}
    tail = {"ty": "gr", "nm": "tail", "it": [
        {"ty": "sh", "ks": {"a": 0, "k": {"c": True, "v": [[130, 330], [236, 330], [138, 402]],
                                           "i": [[0, 0]] * 3, "o": [[0, 0]] * 3}}},
        {"ty": "fl", "c": {"a": 0, "k": [1, 1, 1, 1]}, "o": {"a": 0, "k": 100}},
        {"ty": "tr", "p": {"a": 0, "k": [0, 0]}, "a": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [100, 100]},
         "r": {"a": 0, "k": 0}, "o": {"a": 0, "k": 100}}]}
    shapes = [
        rc([256, 256], [512, 512], 116, rgb(c0), "tile"),
        rc([256, 242], [304, 232], 72, [1, 1, 1, 1], "bubble"),
        tail,
        rc([212, 244], [42, 148], 21, rgb(c0), "F-stem"),
        rc([262, 200], [104, 40], 20, rgb(c0), "F-top"),
        rc([258, 252], [92, 40], 20, rgb(c0), "F-mid"),
    ]
    pulse = {"a": 1, "k": [
        {"t": 0, "s": [96, 96, 100], "i": {"x": [0.5], "y": [1]}, "o": {"x": [0.5], "y": [0]}},
        {"t": 37, "s": [104, 104, 100], "i": {"x": [0.5], "y": [1]}, "o": {"x": [0.5], "y": [0]}},
        {"t": 74, "s": [96, 96, 100]}]}
    return json.dumps({"v": "5.5.7", "fr": 60, "ip": 0, "op": 74, "w": 512, "h": 512, "nm": "FreeChat", "ddd": 0,
                       "assets": [], "layers": [{"ddd": 0, "ind": 1, "ty": 4, "nm": "mark", "sr": 1, "ip": 0, "op": 74, "st": 0,
                                                 "ks": {"o": {"a": 0, "k": 100}, "r": {"a": 0, "k": 0},
                                                         "p": {"a": 0, "k": [256, 256, 0]}, "a": {"a": 0, "k": [256, 256, 0]},
                                                         "s": pulse},
                                                 "shapes": shapes}]}, separators=(",", ":"))


def build_android(m, r, out, root):
    up = os.path.join(root, "android", "upstream")
    if not os.path.isdir(os.path.join(up, "TMessagesProj")):
        sys.exit("gen_icons: android/upstream is missing -- run ./scripts/bootstrap.sh android first.\n"
                 "  The icon set is discovered from it, so the generated files match what upstream ships.")
    res_roots = [d for d in ("TMessagesProj/src/main/res", "TMessagesProj_AppStandalone/src/main/res",
                             "TMessagesProj_App/src/main/res") if os.path.isdir(os.path.join(up, d))]
    raster = re.compile(r"\.(png|webp)$")
    queue = []   # (relative path, job index, format)

    def palette_for(base):
        n = re.match(r"icon_(\d)_", base)
        return ANDROID_PALETTES.get(int(n.group(1))) if n else None

    for rr in res_roots:
        for dp, dn, fs in os.walk(os.path.join(up, rr)):
            for f in sorted(fs):
                if not raster.search(f):
                    continue
                base = f.rsplit(".", 1)[0]
                full = os.path.join(dp, f)
                rel = os.path.relpath(full, up)
                from PIL import Image
                w, h = Image.open(full).size
                pal = palette_for(base)
                mm = m.palette(*pal) if pal else m
                round_ = re.search(r"_round(?:_|$)", base) is not None   # not `"round" in base`: "background" contains it
                if "foreground" in base:
                    svg = m.placed(m.tinted("#FFFFFF"), w, h, 0.56)
                elif re.match(r"icon_\d_background", base):
                    svg = mm.background(round_)
                elif base.startswith("icon_background_clip"):
                    continue    # a corner mask, not artwork
                elif base == "notification":
                    svg = m.placed(m.tinted("#FFFFFF"), w, h, 0.92)
                elif base == "intro_tg_plane":
                    svg = m.placed(m.tinted("#FFFFFF"), w, h, 0.92)
                elif (base.startswith("ic_launcher") or re.match(r"icon_\d_launcher", base)
                      or base in ("ic_launcher_dr", "logo_middle", "server_telegram", "server_freechat")):
                    svg = mm.circle() if round_ else mm.full
                    if base == "ic_launcher_dr" or base.startswith("ic_launcher") and "foreground" in base:
                        pass
                else:
                    continue
                queue.append((rel, r.add(svg, w, h), f.rsplit(".", 1)[1]))
    # the Play Store listing icon lives outside res/
    ps = os.path.join(up, "TMessagesProj/src/main/ic_launcher-playstore.png")
    if os.path.isfile(ps):
        queue.append(("TMessagesProj/src/main/ic_launcher-playstore.png", r.add(m.full, 512, 512), "png"))

    ims = r.run()
    for rel, idx, ext in queue:
        (out.png if ext == "png" else out.webp)(rel, ims[idx])

    # ---- vectors, gradients, wordmark, QR ------------------------------------
    main_res = "TMessagesProj/src/main/res/"
    for dp, dn, fs in os.walk(os.path.join(up, "TMessagesProj/src/main/res/drawable")):
        for f in sorted(fs):
            mt = re.match(r"icon_(?:(\d)_)?background(?:_sa)?\.xml$", f)
            if not mt:
                continue
            txt = read(os.path.join(dp, f))
            if "<gradient" not in txt:
                continue
            start, end = ANDROID_PALETTES.get(int(mt.group(1))) if mt.group(1) else m.gradient_colours()
            out.text(main_res + "drawable/" + f, _sub_gradient(txt, start, end))
    out.text(main_res + "drawable/icon_plane.xml",
             '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
             '    android:width="108dp" android:height="108dp" android:viewportWidth="512" android:viewportHeight="512">\n'
             '  <group android:scaleX="0.56" android:scaleY="0.56" android:pivotX="256" android:pivotY="256">\n'
             f'    <path android:fillColor="#FF000000" android:fillType="evenOdd" android:pathData="{m.path_data()}"/>\n'
             '  </group>\n</vector>\n')
    font = _wordmark_font()
    for name, dp_h in (("telegram_logo", 19.0), ("telegram_logo_2", 20.408922)):
        path, width = _wordmark("FreeChat", 41, font)
        vw = int(width + 16)
        out.text(main_res + f"drawable/{name}.xml",
                 '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
                 f'    android:height="{dp_h}dp" android:width="{dp_h * vw / 57:.2f}dp" '
                 f'android:viewportHeight="57" android:viewportWidth="{vw}">\n'
                 f'  <path android:fillColor="#FFFFFFFF" android:fillType="nonZero" android:pathData="{path}" '
                 'android:translateX="8" android:translateY="8"/>\n</vector>\n')
    c0, _ = m.gradient_colours()
    out.text(main_res + "raw/qr_logo.svg",
             '<?xml version="1.0" encoding="UTF-8"?><svg width="150px" height="150px" viewBox="0 0 150 150" '
             'version="1.1" xmlns="http://www.w3.org/2000/svg">'
             f'<rect x="0" y="0" width="150" height="150" rx="34" fill="{c0}"/>'
             f'<g transform="scale(0.2930)"><path fill="#FFFFFF" d="{m.subpaths()[0]}"/>'
             f'<path fill="{c0}" d="{m.subpaths()[1]}"/></g></svg>')
    out.text(main_res + "raw/plane_logo_plain.json", _lottie(m))


PLATFORMS["android"] = {"build": build_android, "overlay": "android/overlay", "branding": "android/branding",
                        "wants_root": True}


# --------------------------------------------------------------------- desktop
def build_desktop(m, r, out, root):
    up = os.path.join(root, "desktop", "upstream", "Telegram")
    if not os.path.isdir(os.path.join(up, "Resources")):
        sys.exit("gen_icons: desktop/upstream is missing -- run ./scripts/bootstrap.sh desktop first.\n"
                 "  The icon set is discovered from it, so the generated files match what upstream ships.")
    from PIL import Image
    neutral = m.palette("#98A2B3", "#5B6475")
    art_name = re.compile(r"^(icon\d*(@2x)?(_debug)?|icon_green|iconbig_green|icon_round512@2x|logo_256(_no_margin)?|"
                          r"logo_\d+(_\d+)?|logo_debug_1024|business_logo|affiliate_logo|telegram_logo_256)\.png$")
    plate = lambda inner_svg, w, h: (  # a black rounded plate with `inner_svg` on it (the QR centre art)
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}"><rect width="{w}" height="{h}" rx="{w * 0.2:.0f}" fill="#000"/>'
        f'{inner_svg}</svg>')
    queue, icos = [], []

    def add(rel, svg, w, h, ext="png"):
        queue.append((rel, r.add(svg, w, h), ext))

    for dp, dn, fs in os.walk(os.path.join(up, "Resources")):
        reldir = os.path.relpath(dp, up).replace(os.sep, "/")
        for f in sorted(fs):
            rel = f"{reldir}/{f}"
            base = f.rsplit(".", 1)[0]
            if f.endswith(".ico") and base in ("icon256", "icon256_debug"):
                icos.append(rel)
                continue
            if f.endswith(".svg") and reldir == "Resources/FreeChat/icons":
                if base == "plane_white":
                    out.text(rel, m.tinted("#FFFFFF").replace("<svg ", '<svg width="16px" height="16px" ', 1))
                elif base.startswith("tray_monochrome"):
                    colour = "#fc8c03" if base.endswith("attention") else "#9e9e9e"
                    t = m.tinted(colour)
                    if base.endswith("mute"):
                        t = t.replace("<path ", '<path opacity="0.5" ', 1)
                    out.text(rel, t.replace("<svg ", '<svg width="16px" height="16px" ', 1))
                continue
            if not f.endswith(".png"):
                continue
            w, h = Image.open(os.path.join(dp, f)).size
            if reldir == "Resources/icons" and base.startswith("intro_plane_") or base.startswith("intro_qr_plane"):
                kind = re.match(r"intro_(plane_(top|inner|outer|trace)|qr_plane)", base)
                if not kind:
                    continue
                # The cover animates four pieces of one paper plane. The mark has no such
                # parts, so the main piece carries the whole glyph and the rest are empty.
                part = kind.group(2)
                if part in ("inner", "outer", "trace"):
                    svg = f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}"/>'
                else:
                    svg = m.placed(m.tinted("#FFFFFF"), w, h, 0.9)
                add(rel, svg, w, h)
            elif reldir in ("Resources/art", "Resources/FreeChat/art", "Resources/FreeChat/icons") and art_name.match(f):
                if base == "telegram_logo_256":
                    svg = neutral.full           # the "other network" entry: a neutral mark, not another brand's
                elif base == "icon_round512@2x":
                    svg = m.circle()
                elif base == "logo_1024_qr":
                    svg = plate(m.placed(m.full, w, h, 0.78).split(">", 1)[1].rsplit("</svg>", 1)[0], w, h)
                elif base == "logo_1024_qr_white":
                    svg = plate(m.placed(m.tinted("#FFFFFF"), w, h, 0.62).split(">", 1)[1].rsplit("</svg>", 1)[0], w, h)
                else:
                    svg = m.full
                add(rel, svg, w, h)
            elif reldir.startswith("Resources/uwp/AppX/Assets"):
                add(rel, m.placed(m.full, w, h, 0.86), w, h)

    for dp, dn, fs in os.walk(os.path.join(up, "Telegram", "Images.xcassets")):
        for f in sorted(fs):
            if f.endswith(".png"):
                rel = os.path.relpath(os.path.join(dp, f), up).replace(os.sep, "/")
                w, h = Image.open(os.path.join(dp, f)).size
                add(rel, m.placed(m.full, w, h, 0.9), w, h)

    ico_jobs = {s_: r.add(m.full, s_, s_) for s_ in (256, 128, 64, 48, 32, 24, 16)}
    ims = r.run()
    for rel, idx, ext in queue:
        out.png(rel, ims[idx])
    for rel in icos:
        out.ico(rel, [ims[ico_jobs[s_]] for s_ in (256, 128, 64, 48, 32, 24, 16)])


PLATFORMS["desktop"] = {"build": build_desktop, "overlay": "desktop/overlay-late/Telegram", "branding": "desktop/branding",
                        "wants_root": True}

# ------------------------------------------------------------------------ main
def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv
    if len(args) != 2 or args[0] not in PLATFORMS:
        print(__doc__, file=sys.stderr)
        return 2
    plat, root = args[0], os.path.abspath(args[1])
    spec = PLATFORMS[plat]
    branding = os.path.join(root, spec["branding"])
    m = Masters(branding)
    stamp_path = os.path.join(branding, ".logo-stamp")
    have = read(stamp_path).strip() if os.path.isfile(stamp_path) else ""
    if check:
        if have != m.stamp():
            print(f"gen_icons: {plat}: the icons were generated from a different logo than "
                  f"{spec['branding']}/logo.svg + logo-glyph.svg now are.\n  Run: python3 scripts/lib/gen_icons.py {plat} .")
            return 1
        print(f"gen_icons: {plat}: icons match the logo")
        return 0
    r = Renderer(root)
    out = Out(os.path.join(root, spec["overlay"]))
    (spec["build"](m, r, out, root) if spec.get("wants_root") else spec["build"](m, r, out))
    n = out.write()
    with open(stamp_path, "w", encoding="utf-8") as fh:
        fh.write(m.stamp() + "\n")
    print(f"gen_icons: {plat}: {n} files (renderer: {r.tool})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
