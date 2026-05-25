from PIL import Image, ImageDraw
import math

SIZE = 1024
cx, cy = SIZE // 2, SIZE // 2

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

# Background: dark navy rounded square
def rounded_rect(draw, xy, radius, fill):
    x0, y0, x1, y1 = xy
    draw.rectangle([x0 + radius, y0, x1 - radius, y1], fill=fill)
    draw.rectangle([x0, y0 + radius, x1, y1 - radius], fill=fill)
    draw.ellipse([x0, y0, x0 + radius * 2, y0 + radius * 2], fill=fill)
    draw.ellipse([x1 - radius * 2, y0, x1, y0 + radius * 2], fill=fill)
    draw.ellipse([x0, y1 - radius * 2, x0 + radius * 2, y1], fill=fill)
    draw.ellipse([x1 - radius * 2, y1 - radius * 2, x1, y1], fill=fill)

rounded_rect(draw, [0, 0, SIZE - 1, SIZE - 1], 180, (10, 14, 30, 255))

# Subtle dark radial gradient overlay using concentric circles
for r in range(500, 0, -4):
    alpha = int(40 * (r / 500) ** 2)
    color = (5, 10, 25, alpha)
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=color)

CYAN = (0, 212, 255)
CYAN_DIM = (0, 140, 180)
CYAN_GLOW = (0, 212, 255, 60)
WHITE = (255, 255, 255)

def glow_circle(draw, cx, cy, r, width, color, glow_layers=6):
    base_r, base_g, base_b = color
    for i in range(glow_layers, 0, -1):
        alpha = int(40 * (i / glow_layers))
        extra = i * 5
        draw.ellipse(
            [cx - r - extra, cy - r - extra, cx + r + extra, cy + r + extra],
            outline=(base_r, base_g, base_b, alpha),
            width=width + extra,
        )
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], outline=color + (255,), width=width)

def glow_line(draw, x0, y0, x1, y1, width, color, glow_layers=5):
    base_r, base_g, base_b = color
    for i in range(glow_layers, 0, -1):
        alpha = int(50 * (i / glow_layers))
        extra = i * 3
        draw.line([x0, y0, x1, y1], fill=(base_r, base_g, base_b, alpha), width=width + extra * 2)
    draw.line([x0, y0, x1, y1], fill=color + (255,), width=width)

# Outer ring
glow_circle(draw, cx, cy, 380, 6, CYAN)

# Tick marks on outer ring
for angle_deg in range(0, 360, 15):
    angle = math.radians(angle_deg)
    is_major = angle_deg % 90 == 0
    is_mid   = angle_deg % 45 == 0 and not is_major
    inner_r  = 345 if is_major else (355 if is_mid else 362)
    outer_r  = 380
    w = 5 if is_major else (4 if is_mid else 3)
    x0 = cx + inner_r * math.cos(angle)
    y0 = cy + inner_r * math.sin(angle)
    x1 = cx + outer_r * math.cos(angle)
    y1 = cy + outer_r * math.sin(angle)
    draw.line([x0, y0, x1, y1], fill=CYAN + (255,), width=w)

# Middle ring
glow_circle(draw, cx, cy, 260, 4, CYAN_DIM)

# Inner ring
glow_circle(draw, cx, cy, 120, 5, CYAN)

# Crosshair lines — gap in the center
gap = 135
arm = 370

# Horizontal
glow_line(draw, cx - arm, cy, cx - gap, cy, 4, CYAN)
glow_line(draw, cx + gap, cy, cx + arm, cy, 4, CYAN)
# Vertical
glow_line(draw, cx, cy - arm, cx, cy - gap, 4, CYAN)
glow_line(draw, cx, cy + gap, cx, cy + arm, 4, CYAN)

# Corner brackets (top-left, top-right, bottom-left, bottom-right)
bracket_r = 260
blen = 70
bw = 6
for dx, dy in [(-1, -1), (1, -1), (-1, 1), (1, 1)]:
    bx = cx + dx * bracket_r
    by = cy + dy * bracket_r
    # horizontal arm
    glow_line(draw, bx, by, bx + dx * blen, by, bw, CYAN)
    # vertical arm
    glow_line(draw, bx, by, bx, by + dy * blen, bw, CYAN)

# Center dot with intense glow
for r in range(28, 0, -2):
    alpha = int(180 * (1 - r / 28) ** 0.5)
    draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(0, 212, 255, alpha))
draw.ellipse([cx - 8, cy - 8, cx + 8, cy + 8], fill=WHITE + (255,))

# Diamond pip marks at 90° positions on middle ring
for angle_deg in [0, 90, 180, 270]:
    angle = math.radians(angle_deg)
    px = cx + 260 * math.cos(angle)
    py = cy + 260 * math.sin(angle)
    s = 10
    pts = [(px, py - s), (px + s, py), (px, py + s), (px - s, py)]
    draw.polygon(pts, fill=CYAN + (255,))

img.save("/home/user/ApexSight/assets/icon.png", "PNG")
print("icon.png written")

# Also generate a 96x96 notification icon (white on transparent)
notif = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
nd = ImageDraw.Draw(notif)
nc = 48
# simple crosshair circle for notification
nd.ellipse([8, 8, 88, 88], outline=(255, 255, 255, 255), width=4)
nd.ellipse([24, 24, 72, 72], outline=(255, 255, 255, 200), width=3)
nd.line([nc, 10, nc, 35], fill=(255, 255, 255, 255), width=3)
nd.line([nc, 61, nc, 86], fill=(255, 255, 255, 255), width=3)
nd.line([10, nc, 35, nc], fill=(255, 255, 255, 255), width=3)
nd.line([61, nc, 86, nc], fill=(255, 255, 255, 255), width=3)
nd.ellipse([44, 44, 52, 52], fill=(255, 255, 255, 255))
notif.save("/home/user/ApexSight/assets/notification-icon.png", "PNG")
print("notification-icon.png written")
