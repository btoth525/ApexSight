"""
Generates icon.png (1024×1024) and notification-icon.png (96×96).
Icon: dark background + Frigate frigatebird silhouette in blue.
"""

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
BG   = (10, 14, 26, 255)
BLUE = (30, 110, 255)

# ── helpers ───────────────────────────────────────────────────────────────────

def rrect(d, x0, y0, x1, y1, r, fill):
    d.rectangle([x0+r, y0, x1-r, y1], fill=fill)
    d.rectangle([x0, y0+r, x1, y1-r], fill=fill)
    for cx, cy in [(x0,y0),(x1-2*r,y0),(x0,y1-2*r),(x1-2*r,y1-2*r)]:
        d.ellipse([cx, cy, cx+2*r, cy+2*r], fill=fill)

def scale(pts, s=1.0, ox=0, oy=0):
    """Scale + offset a list of (x,y) tuples that live in 0-1000 space → pixel coords."""
    return [(int(x * s + ox), int(y * s + oy)) for x, y in pts]

# ── frigatebird silhouette (traced in 0-1000 coordinate space) ────────────────
# Clockwise from upper-right wing tip.
# This matches the classic Frigate NVR logo — a frigatebird banking in flight.

BIRD = [
    # ── upper-right wing, tip → body (upper/trailing edge) ──────────────────
    (930, 82),
    (870, 106), (800, 132), (718, 162), (640, 196),
    (572, 224), (510, 250), (462, 268), (420, 278),

    # ── wing kink into shoulder ──────────────────────────────────────────────
    (392, 282), (374, 285),

    # ── head (small bump top-left of body) ──────────────────────────────────
    (358, 268), (340, 252), (316, 246), (295, 252),
    (280, 268), (280, 288), (296, 304), (322, 312),

    # ── neck → waist ─────────────────────────────────────────────────────────
    (335, 334), (340, 372), (352, 402),

    # ── body → tail (right side) ─────────────────────────────────────────────
    (378, 418), (440, 428), (514, 428),

    # ── upper tail fork ──────────────────────────────────────────────────────
    (574, 420), (634, 404), (678, 388),
    (706, 384), (722, 394), (720, 414),
    (702, 426), (666, 432), (626, 434),

    # ── gap between fork prongs ──────────────────────────────────────────────
    (596, 442), (572, 456),

    # ── lower tail fork ──────────────────────────────────────────────────────
    (592, 470), (624, 476), (660, 468), (682, 456),

    # ── lower body (right → left) ────────────────────────────────────────────
    (692, 460), (668, 478), (630, 484),
    (580, 482), (524, 476), (470, 468),
    (428, 462), (400, 468),

    # ── lower-left wing, body → tip (leading/upper edge) ─────────────────────
    (372, 490), (346, 516), (314, 556),
    (278, 614), (236, 694), (188, 780),
    (148, 856), (112, 906),

    # ── lower-left wing tip ───────────────────────────────────────────────────
    (100, 922),

    # ── lower-left wing, tip → body (trailing/lower edge) ────────────────────
    (130, 944), (182, 916), (252, 874),
    (322, 826), (386, 760), (430, 696),
    (452, 636), (462, 582), (456, 544),

    # ── back to lower-left body ───────────────────────────────────────────────
    (440, 502), (408, 478),

    # ── left body wall, back up to neck ──────────────────────────────────────
    (370, 452), (350, 420), (340, 382),
    (334, 344), (322, 308), (296, 290),
    # closes back near head → shoulder → we've come full circle
]

# ── build icon ────────────────────────────────────────────────────────────────

img  = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)
rrect(draw, 0, 0, SIZE, SIZE, 200, BG)

# Soft glow behind the bird
glow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gd   = ImageDraw.Draw(glow)
gd.ellipse([150, 150, 874, 874], fill=(30, 110, 255, 28))
glow = glow.filter(ImageFilter.GaussianBlur(90))
img  = Image.alpha_composite(img, glow)
draw = ImageDraw.Draw(img)

# Fit the 0-1000 bird into roughly 88% of the canvas, centered
margin = SIZE * 0.06
usable = SIZE - 2 * margin
sc     = usable / 1000.0
pts    = scale(BIRD, s=sc, ox=margin, oy=margin)

r, g, b = BLUE
draw.polygon(pts, fill=(r, g, b, 255))

# Subtle inner highlight (lighter blue overlay, top portion of bird)
highlight = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
hd = ImageDraw.Draw(highlight)
hd.polygon(pts, fill=(80, 160, 255, 55))
highlight = highlight.filter(ImageFilter.GaussianBlur(6))
img = Image.alpha_composite(img, highlight)

img.save("/home/user/ApexSight/assets/icon.png", "PNG")
print("icon.png written")

# ── notification icon 96×96 (white silhouette, no background) ─────────────────
notif = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
nd    = ImageDraw.Draw(notif)
small = scale(BIRD, s=96/1000 * 0.88, ox=96*0.06, oy=96*0.06)
nd.polygon(small, fill=(255, 255, 255, 255))
notif.save("/home/user/ApexSight/assets/notification-icon.png", "PNG")
print("notification-icon.png written")
