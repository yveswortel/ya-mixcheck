#!/usr/bin/env python3
"""Create the separate English guide; never modifies the app or released DMG."""
import json
from pathlib import Path
from reportlab.pdfgen import canvas
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.lib.colors import HexColor

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Assets/Installer/Installation.en.pdf"
VERSION = json.loads((ROOT / "ReleaseConfig.json").read_text())["version"]
FONT = Path("/System/Library/Fonts/Supplemental")
for name, filename in {"serif": "Georgia.ttf", "sans": "Arial.ttf", "bold": "Arial Bold.ttf"}.items():
    pdfmetrics.registerFont(TTFont(name, str(FONT / filename)))

c = canvas.Canvas(str(OUT), pagesize=(520, 650), pageCompression=1, invariant=1)
c.setTitle("YA-MixCheck - Installation")
c.setAuthor("Yves Wortel / Yves Audio")
c.setSubject(f"Short installation guide for YA-MixCheck {VERSION}")
c.setFillColor(HexColor("#F2F0E9"))
c.rect(0, 0, 520, 650, fill=1, stroke=0)

def line(x, top, text, size=12, family="sans", color="#171917"):
    # Catch accidental overflow when editing translations or version labels.
    assert pdfmetrics.stringWidth(text, family, size) <= 480 - x, text
    c.setFillColor(HexColor(color))
    c.setFont(family, size)
    c.drawString(x, 650 - top, text)

def rule(top):
    c.setStrokeColor(HexColor("#C9C8BF"))
    c.setLineWidth(0.6)
    c.line(40, 650 - top, 480, 650 - top)

line(40, 39, "Yves Wortel", 12, color="#60665C")
line(40, 95, "YA / MixCheck", 36, "serif")
line(41, 124, f"Installation  /  {VERSION}", 12, color="#60665C")
line(41, 151, "Apple Silicon (M1 or later), running macOS 15 or later.", 11, color="#60665C")
rule(174)
line(40, 205, "1", 16, "serif", "#60665C")
line(68, 205, "Drag to Applications", 15, "bold")
line(68, 228, "Open the DMG. Drag YA-MixCheck to the Apps shortcut.")
line(40, 269, "2", 16, "serif", "#60665C")
line(68, 269, "Open from Applications", 15, "bold")
line(68, 292, "Open YA-MixCheck from Applications, outside the DMG.")
line(68, 312, "You can then eject the DMG.")
c.setFillColor(HexColor("#E8E7DF"))
c.roundRect(40, 650 - 496, 440, 153, 8, fill=1, stroke=0)
line(58, 372, "Does macOS block the first launch?", 15, "bold")
line(58, 396, "This version is not notarized by Apple.", 11, color="#60665C")
line(58, 421, "After trying to open it, go to System Settings.", 11)
line(58, 442, "Select Privacy & Security and scroll to Open Anyway.", 11)
line(58, 463, "Click Open Anyway, then confirm with Open.", 11, "bold")
line(58, 483, "Only do this for the package received from Yves or this repository.", 10, color="#60665C")
line(40, 526, "Ready. Drop an audio file into the app to get started.", 12)
line(40, 550, "The 1.0 app interface and reports are currently in Dutch.", 10, color="#60665C")
rule(578)
line(40, 604, "yveswortel.com", 11, color="#60665C")
c.linkURL("https://yveswortel.com", (40, 40, 128, 58), relative=0)
line(354, 604, "Apple: open safely", 10, color="#60665C")
c.linkURL("https://support.apple.com/en-us/102445", (354, 40, 480, 58), relative=0)
c.showPage()
c.save()
print(OUT)
