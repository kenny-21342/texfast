"""Generate TexFast.icns or TexFastRealtime.icns with --variant realtime.

The standard icon uses a purple page and bolt; realtime uses teal and a live waveform. Drawn at
4x and downsampled so the curves stay clean at 16px, where most of these are
actually seen.
"""
from PIL import Image, ImageDraw
import argparse, math, os, subprocess

parser = argparse.ArgumentParser(description="Generate the standard or realtime TexFast icon")
parser.add_argument("--variant", choices=("standard", "realtime"), default="standard")
args = parser.parse_args()
realtime = args.variant == "realtime"
prefix = "TexFastRealtime" if realtime else "TexFast"
os.chdir(os.path.dirname(os.path.abspath(__file__)))

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
top, bottom = ((5, 67, 74), (16, 167, 150)) if realtime else ((46, 32, 122), (124, 78, 237))
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
          fill=(186, 231, 223, 255) if realtime else (206, 200, 232, 255))

# --- text lines, with a centred bar standing in for a displayed equation ---
line_x0, line_x1 = px + int(52*K), px + pw - int(52*K)
span = line_x1 - line_x0
ly = py + int(150*K)
for width, centred in [(1.0, False), (0.82, False), (0.44, True), (0.93, False), (0.62, False)]:
    if centred:
        x0 = line_x0 + span*(1-width)/2
        colour = (12, 142, 130, 255) if realtime else (109, 75, 232, 255)      # the equation reads as ink, not body text
    else:
        x0, colour = line_x0, ((123, 160, 157, 255) if realtime else (150, 143, 178, 255))
    d.rounded_rectangle([x0, ly, x0 + span*width, ly + int(26*K)],
                        radius=int(13*K), fill=colour)
    ly += int(58*K) if not centred else int(66*K)

if realtime:
    # --- live waveform: a distinct silhouette as well as a distinct color ---
    pts = [(x*K, y*K) for x,y in [(420,600),(495,600),(540,520),(600,735),(665,425),(725,600),(850,600)]]
    for color, width in [((5,67,74,255), 48), ((199,255,88,255), 30)]:
        d.line(pts, fill=color, width=int(width*K), joint="curve")
        r=width*K/2
        for x,y in pts:
            d.ellipse([x-r,y-r,x+r,y+r], fill=color)
else:
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

os.makedirs(f"{prefix}.iconset", exist_ok=True)
for pt in (16, 32, 128, 256, 512):
    icon.resize((pt, pt), Image.LANCZOS).save(f"{prefix}.iconset/icon_{pt}x{pt}.png")
    icon.resize((pt*2, pt*2), Image.LANCZOS).save(f"{prefix}.iconset/icon_{pt}x{pt}@2x.png")
icon.save("realtime-icon-preview.png" if realtime else "icon-preview.png")
subprocess.run(["iconutil", "-c", "icns", f"{prefix}.iconset", "-o", f"{prefix}.icns"], check=True)
print("wrote", f"{prefix}.icns", os.path.getsize(f"{prefix}.icns"), "bytes")
