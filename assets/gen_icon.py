"""
Generates icon.png (1024×1024) and notification-icon.png (96×96)
for the Apex app.

Icon: dark navy background, Frigate-style Great Blue Heron silhouette
      in electric blue (#00B4D8), facing right.
"""

from PIL import Image, ImageDraw, ImageFilter
import math

SIZE = 1024
BLUE  = (30, 110, 255)
BLUE2 = (10,  70, 200)
BG    = (10, 14, 26, 255)

img  = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

def rrect(d, x0, y0, x1, y1, r, fill):
    d.rectangle([x0+r, y0, x1-r, y1], fill=fill)
    d.rectangle([x0, y0+r, x1, y1-r], fill=fill)
    for cx, cy in [(x0,y0),(x1-2*r,y0),(x0,y1-2*r),(x1-2*r,y1-2*r)]:
        d.ellipse([cx, cy, cx+2*r, cy+2*r], fill=fill)

rrect(draw, 0, 0, SIZE, SIZE, 200, BG)

# Subtle glow behind bird
glow = Image.new("RGBA", (SIZE, SIZE), (0,0,0,0))
gd   = ImageDraw.Draw(glow)
gd.ellipse([280, 220, 780, 820], fill=(0, 140, 220, 30))
glow = glow.filter(ImageFilter.GaussianBlur(80))
img  = Image.alpha_composite(img, glow)
draw = ImageDraw.Draw(img)

def sc(v): return int(v * SIZE / 1024)

def poly(pts, fill, alpha=255):
    r, g, b = fill
    draw.polygon([(sc(x), sc(y)) for x,y in pts], fill=(r,g,b,alpha))

def ellipse(cx, cy, rx, ry, fill, alpha=255):
    r, g, b = fill
    draw.ellipse([sc(cx-rx), sc(cy-ry), sc(cx+rx), sc(cy+ry)], fill=(r,g,b,alpha))

def ln(x0, y0, x1, y1, fill, width, alpha=255):
    r, g, b = fill
    draw.line([sc(x0), sc(y0), sc(x1), sc(y1)], fill=(r,g,b,alpha), width=sc(width))

# Body
poly([
    (310, 555), (290, 590), (330, 640), (480, 660),
    (620, 630), (640, 595), (590, 555), (420, 540), (330, 540),
], BLUE)

# Wing fold (darker shade for depth)
poly([
    (340, 548), (520, 545), (590, 560), (610, 590),
    (550, 610), (380, 620), (320, 600), (310, 570),
], BLUE2)

# Trailing feathers
for i, (fx, fy) in enumerate([(490,650),(530,655),(565,645),(595,630)]):
    poly([(fx-18, 622),(fx, fy),(fx+18, 622)], BLUE if i%2==0 else BLUE2)

# Neck (S-curve)
poly([
    (310, 555), (290, 555), (260, 490), (280, 410), (330, 350),
    (360, 355), (340, 420), (330, 490), (345, 550),
], BLUE)

# Head
ellipse(345, 318, 52, 46, BLUE)

# Crest feathers
poly([(300,308),(230,285),(215,295),(225,310),(295,325)], BLUE)
poly([(295,320),(220,310),(205,322),(215,332),(290,332)], BLUE2)

# Beak
poly([(385,308),(560,320),(385,330)], BLUE)
ln(385, 321, 555, 321, BLUE2, 3)

# Eye
ellipse(363, 308, 13, 11, (220, 240, 255))
ellipse(365, 308,  7,  7, (5, 10, 20))
ellipse(368, 305,  3,  3, (255, 255, 255))

# Legs
ln(370, 660, 340, 800, BLUE, 9)
ln(420, 665, 395, 800, BLUE, 9)

# Toes
for (ax, ay), toes in [
    ((340, 800), [(295,815),(330,825),(360,820),(340,840)]),
    ((395, 800), [(350,815),(385,825),(415,820),(395,840)]),
]:
    for tx, ty in toes:
        ln(ax, ay, tx, ty, BLUE, 7)

# Back highlight
poly([
    (340,545),(450,535),(550,548),(540,560),(430,550),(335,558),
], (80, 200, 255), alpha=60)

img.save("/home/user/ApexSight/assets/icon.png", "PNG")
print("icon.png written (1024x1024)")

# Notification icon — 96x96 white heron on transparent
notif = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
nd    = ImageDraw.Draw(notif)
W = (255, 255, 255, 255)
nd.polygon([(20,60),(18,68),(22,74),(48,76),(62,72),(64,66),(58,58),(38,56)], fill=W)
nd.polygon([(20,58),(17,58),(14,48),(16,36),(24,30),(27,31),(25,42),(22,52)], fill=W)
nd.ellipse([18,22,36,36], fill=W)
nd.polygon([(32,27),(62,29),(32,33)], fill=W)
nd.line([(30,76),(28,90)], fill=W, width=3)
nd.line([(42,77),(40,90)], fill=W, width=3)
notif.save("/home/user/ApexSight/assets/notification-icon.png", "PNG")
print("notification-icon.png written (96x96)")
