#!/usr/bin/env python3
"""Small offline installer artwork. Requires Pillow and ReportLab; no app changes."""
import json
from pathlib import Path
import subprocess

from PIL import Image, ImageDraw, ImageFont
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.colors import HexColor

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Assets/Installer"
OUT.mkdir(parents=True, exist_ok=True)
CONFIG = json.loads((ROOT / "ReleaseConfig.json").read_text())
VERSION = CONFIG["version"]
PAPER, INK, MUTED, LINE, SOFT = "#F2F0E9", "#171917", "#60665C", "#C9C8BF", "#E8E7DF"
FONT = Path("/System/Library/Fonts/Supplemental")
FONTS = {"serif": FONT / "Georgia.ttf", "sans": FONT / "Arial.ttf", "bold": FONT / "Arial Bold.ttf"}

# Finder uses logical points. A multi-resolution TIFF retains crisp Retina text
# while keeping the window background at exactly 700 x 490 points.
for scale, suffix in ((1, ""), (2, "@2x")):
    im = Image.new("RGB", (700 * scale, 490 * scale), PAPER)
    d = ImageDraw.Draw(im)

    def text(x, y, s, size, family="sans", color=INK, anchor="lt"):
        d.text((x * scale, y * scale), s,
               font=ImageFont.truetype(str(FONTS[family]), size * scale),
               fill=color, anchor=anchor)

    text(40, 30, "Yves Wortel", 14, color=MUTED)
    text(660, 30, VERSION, 14, color=MUTED, anchor="rt")
    text(40, 69, "YA / MixCheck", 43, "serif")
    text(42, 129, "Sleep de app naar Apps.", 17)
    # Real Finder app and Applications icons sit at (190, 244) and (510, 244).
    d.line([(318 * scale, 244 * scale), (382 * scale, 244 * scale)], fill=MUTED, width=2 * scale)
    d.line([(373 * scale, 235 * scale), (382 * scale, 244 * scale), (373 * scale, 253 * scale)], fill=MUTED, width=2 * scale)
    d.line([(40 * scale, 340 * scale), (660 * scale, 340 * scale)], fill=LINE, width=scale)
    # The third Finder item is the guide, at (106, 399).
    text(194, 373, "Eerste keer openen?", 21, "serif")
    text(194, 409, "Lees Installatie voor de stap ‘Open toch’.", 14, color=MUTED)
    text(660, 465, "Apple Silicon · macOS 15 of nieuwer", 11, color=MUTED, anchor="rt")
    im.save(OUT / f"background{suffix}.png", dpi=(72 * scale, 72 * scale))

subprocess.run(["/usr/bin/tiffutil", "-cathidpicheck", str(OUT / "background.png"),
                str(OUT / "background@2x.png"), "-out", str(OUT / "background.tiff")], check=True)

for name, path in FONTS.items():
    pdfmetrics.registerFont(TTFont(name, str(path)))

# A compact single page: no marketing, no developer prerequisites, no shell steps.
c = canvas.Canvas(str(OUT / "Installatie.pdf"), pagesize=(520, 624), pageCompression=1)
c.setTitle("YA-MixCheck - Installatie")
c.setAuthor("Yves Wortel / Yves Audio")
c.setSubject(f"Korte installatiehandleiding voor YA-MixCheck {VERSION}")
c.setFillColor(HexColor(PAPER))
c.rect(0, 0, 520, 624, fill=1, stroke=0)

def line(x, top, s, size=12, family="sans", color=INK):
    c.setFillColor(HexColor(color))
    c.setFont(family, size)
    c.drawString(x, 624 - top, s)

def rule(top):
    c.setStrokeColor(HexColor(LINE))
    c.setLineWidth(0.6)
    c.line(40, 624 - top, 480, 624 - top)

line(40, 39, "Yves Wortel", 12, color=MUTED)
line(40, 95, "YA / MixCheck", 36, "serif")
line(41, 124, f"Installatie  /  {VERSION}", 12, color=MUTED)
line(41, 151, "Voor Apple Silicon (M1 of nieuwer), met macOS 15 of nieuwer.", 11, color=MUTED)
rule(174)
line(40, 205, "1", 16, "serif", MUTED)
line(68, 205, "Sleep naar Apps", 15, "bold")
line(68, 228, "Open de DMG en sleep YA-MixCheck naar de map Apps.")
line(40, 269, "2", 16, "serif", MUTED)
line(68, 269, "Open vanuit Apps", 15, "bold")
line(68, 292, "Open YA-MixCheck vanuit Apps, niet vanuit de DMG.")
line(68, 312, "Daarna kun je de DMG uitwerpen.")

c.setFillColor(HexColor(SOFT))
c.roundRect(40, 624 - 496, 440, 153, 8, fill=1, stroke=0)
line(58, 372, "Blokkeert macOS de eerste start?", 15, "bold")
line(58, 396, "Deze testversie is niet door Apple genotariseerd.", 11, color=MUTED)
line(58, 421, "Na je eerste openingspoging: open Systeeminstellingen.", 11)
line(58, 442, "Ga naar Privacy en beveiliging en scrol naar Open toch.", 11)
line(58, 463, "Klik op Open toch en bevestig met Open.", 11, "bold")
line(58, 483, "Doe dit alleen voor het pakket dat je van Yves hebt ontvangen.", 10, color=MUTED)

line(40, 526, "Klaar. Sleep een audiobestand in de app om te beginnen.", 12)
rule(551)
line(40, 576, "yveswortel.com", 11, color=MUTED)
c.linkURL("https://yveswortel.com", (40, 43, 128, 60), relative=0)
line(354, 576, "Apple: veilig openen", 10, color=MUTED)
c.linkURL("https://support.apple.com/nl-nl/102445", (354, 43, 480, 60), relative=0)
c.showPage()
c.save()
print(OUT)
