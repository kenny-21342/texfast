"""Generate TexFast.icns.

A document page with a lightning bolt: 'a LaTeX file, compiled fast'. Drawn at
4x and downsampled so the curves stay clean at 16px, where most of these are
actually seen.
"""
from PIL import Image, ImageDraw
import math, os, subprocess

S = 4096              # working canvas (4x the 1024 icon)
K = S / 1024.0        # scale from icon points to working pixels

def lerp(a, b, t): return tuple(int(round(a[i] + (b[i]-a[i])*t)) for i in range(3))

def squircle_mask(size, radius):
    m = Image.new("L", (size[0]*1, size[1]*1), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size[0]-1, size[1]-1], radius=radius, fill=255)
    return m

canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

# --- rounded-square body, indigo -> violet, on the standard macOS inset ---
inset = int(100 * K)
side  = S - inset*2
top, bottom = (46, 32, 122), (124, 78, 237)
grad = Image.new("RGB", (1, side))
for y in range(side):
    grad.putpixel((0, y), lerp(top, bottom, y/(side-1)))
grad = grad.resize((side, side))
body = Image.new("RGBA", (side, side), (0,0,0,0))
body.paste(grad, (0, 0))
body.putalpha(squircle_mask((side, side), int(185 * K)))
canvas.alpha_composite(body, (inset, inset))

d = ImageDraw.Draw(canvas)

# --- the page ---
pw, ph = int(400*K), int(500*K)
px, py = int(300*K), int(250*K)
fold = int(96*K)
d.polygon([(px, py), (px+pw-fold, py), (px+pw, py+fold), (px+pw, py+ph), (px, py+ph)],
          fill=(255, 255, 255, 255))
# folded corner, slightly darker so it reads as a fold and not a notch
d.polygon([(px+pw-fold, py), (px+pw, py+fold), (px+pw-fold, py+fold)],
          fill=(206, 200, 232, 255))

# --- text lines, with a centred bar standing in for a displayed equation ---
line_x0, line_x1 = px + int(52*K), px + pw - int(52*K)
span = line_x1 - line_x0
ly = py + int(150*K)
for width, centred in [(1.0, False), (0.82, False), (0.44, True), (0.93, False), (0.62, False)]:
    if centred:
        x0 = line_x0 + span*(1-width)/2
        colour = (109, 75, 232, 255)      # the equation reads as ink, not body text
    else:
        x0, colour = line_x0, (150, 143, 178, 255)
    d.rounded_rectangle([x0, ly, x0 + span*width, ly + int(26*K)],
                        radius=int(13*K), fill=colour)
    ly += int(58*K) if not centred else int(66*K)

# --- lightning bolt, overlapping the page and breaking its edge ---
bolt = [(58,2),(16,56),(44,56),(30,98),(84,40),(54,40)]
bw, bh = int(430*K), int(470*K)
bx, by = int(455*K), int(360*K)
pts = [(bx + x/100*bw, by + y/100*bh) for x, y in bolt]
# dark halo first so the bolt stays legible against the white page
d.polygon([(x, y) for x, y in pts], fill=(46, 32, 122, 255))
shrink = 0.955
cx = sum(p[0] for p in pts)/len(pts); cy = sum(p[1] for p in pts)/len(pts)
d.polygon([(cx + (x-cx)*shrink, cy + (y-cy)*shrink) for x, y in pts],
          fill=(255, 199, 61, 255))

icon = canvas.resize((1024, 1024), Image.LANCZOS)

os.makedirs("TexFast.iconset", exist_ok=True)
for pt in (16, 32, 128, 256, 512):
    icon.resize((pt, pt), Image.LANCZOS).save(f"TexFast.iconset/icon_{pt}x{pt}.png")
    icon.resize((pt*2, pt*2), Image.LANCZOS).save(f"TexFast.iconset/icon_{pt}x{pt}@2x.png")
icon.save("icon-preview.png")
subprocess.run(["iconutil", "-c", "icns", "TexFast.iconset", "-o", "TexFast.icns"], check=True)
print("wrote TexFast.icns", os.path.getsize("TexFast.icns"), "bytes")
