from PIL import Image, ImageDraw
import math

SIZE = 1024
cx, cy = SIZE // 2, SIZE // 2

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(img)

CYAN  = (0, 220, 255)
CYAN2 = (0, 160, 200)
WHITE = (255, 255, 255)
RED   = (255, 50, 50)
BG    = (8, 12, 24, 255)

# ── helpers ──────────────────────────────────────────────────────────────────

def rounded_rect_fill(draw, x0, y0, x1, y1, r, fill):
    draw.rectangle([x0 + r, y0, x1 - r, y1], fill=fill)
    draw.rectangle([x0, y0 + r, x1, y1 - r], fill=fill)
    for ex, ey in [(x0, y0), (x1 - 2*r, y0), (x0, y1 - 2*r), (x1 - 2*r, y1 - 2*r)]:
        draw.ellipse([ex, ey, ex + 2*r, ey + 2*r], fill=fill)

def glow_ellipse(draw, cx, cy, rx, ry, width, color, layers=7):
    r, g, b = color
    for i in range(layers, 0, -1):
        e = i * 6
        a = int(35 * i / layers)
        draw.ellipse([cx-rx-e, cy-ry-e, cx+rx+e, cy+ry+e],
                     outline=(r, g, b, a), width=width + e)
    draw.ellipse([cx-rx, cy-ry, cx+rx, cy+ry], outline=(r, g, b, 255), width=width)

def glow_line(draw, x0, y0, x1, y1, width, color, layers=6):
    r, g, b = color
    for i in range(layers, 0, -1):
        e = i * 4
        a = int(40 * i / layers)
        draw.line([x0, y0, x1, y1], fill=(r, g, b, a), width=width + e)
    draw.line([x0, y0, x1, y1], fill=(r, g, b, 255), width=width)

def glow_poly(draw, pts, fill, glow_color, layers=5):
    r, g, b = glow_color
    for i in range(layers, 0, -1):
        a = int(50 * i / layers)
        draw.polygon(pts, fill=(r, g, b, a))
    draw.polygon(pts, fill=fill + (255,))

# ── background ───────────────────────────────────────────────────────────────

rounded_rect_fill(draw, 0, 0, SIZE, SIZE, 180, BG)

# vignette
for r in range(520, 0, -5):
    a = int(60 * (r / 520) ** 2)
    draw.ellipse([cx-r, cy-r, cx+r, cy+r], fill=(0, 0, 0, a))

# ── camera body (bullet/PTZ housing) ─────────────────────────────────────────
# Drawn as a 3/4 perspective: body goes top-left → bottom-right
# The camera "barrel" points toward viewer-right

# Camera housing body — dark slate rectangle with rounded ends, tilted via polygon
body_color   = (18, 28, 50, 255)
body_edge    = (30, 50, 80, 255)
panel_color  = (12, 20, 38, 255)

# Horizontal bullet cam, centered slightly above mid
cam_cx, cam_cy = cx, cy - 30

# Main housing: pill shape (wide rounded rect)
bw, bh = 580, 200
bx0, by0 = cam_cx - bw//2, cam_cy - bh//2
bx1, by1 = cam_cx + bw//2, cam_cy + bh//2

# Fill body
rounded_rect_fill(draw, bx0, by0, bx1, by1, bh//2, body_color)

# Body edge highlight (top)
draw.rectangle([bx0 + bh//2, by0, bx1 - bh//2, by0 + 12], fill=(40, 70, 110, 255))

# Mount bracket on top-center
brkt_w, brkt_h = 120, 90
brkx = cam_cx - brkt_w // 2
draw.rectangle([brkx, by0 - brkt_h, brkx + brkt_w, by0 + 20],
               fill=(14, 22, 42, 255))
draw.rectangle([brkx, by0 - brkt_h, brkx + brkt_w, by0 - brkt_h + 14],
               fill=CYAN2 + (255,))
# mounting screws
for sx in [brkx + 25, brkx + brkt_w - 25]:
    sy = by0 - brkt_h // 2
    draw.ellipse([sx-8, sy-8, sx+8, sy+8], fill=(25, 40, 65, 255))
    draw.ellipse([sx-5, sy-5, sx+5, sy+5], outline=CYAN2+(200,), width=2)

# Lens housing — circle on the right end
lens_cx = bx1 - bh//2
lens_cy = cam_cy
lens_r  = bh // 2 - 4

# lens barrel outer ring
draw.ellipse([lens_cx-lens_r-8, lens_cy-lens_r-8,
              lens_cx+lens_r+8, lens_cy+lens_r+8],
             fill=(25, 38, 62, 255))
glow_ellipse(draw, lens_cx, lens_cy, lens_r, lens_r, 5, CYAN)

# lens glass layers
for ri, col in [
    (lens_r - 5,  (10, 15, 30, 255)),
    (lens_r - 22, (15, 25, 50, 255)),
    (lens_r - 40, (8,  18, 40, 255)),
    (lens_r - 54, (20, 35, 65, 255)),
]:
    draw.ellipse([lens_cx-ri, lens_cy-ri, lens_cx+ri, lens_cy+ri], fill=col)

# aperture blades (hexagonal iris)
blade_r_out = lens_r - 28
blade_r_in  = lens_r - 58
num_blades  = 6
blade_pts_list = []
for i in range(num_blades):
    a0 = math.radians(i * 60 - 15)
    a1 = math.radians(i * 60 + 15)
    a2 = math.radians(i * 60 + 45)
    a3 = math.radians(i * 60 + 15 + 30)
    pts = [
        (lens_cx + blade_r_out * math.cos(a0), lens_cy + blade_r_out * math.sin(a0)),
        (lens_cx + blade_r_out * math.cos(a1), lens_cy + blade_r_out * math.sin(a1)),
        (lens_cx + blade_r_in  * math.cos(a3), lens_cy + blade_r_in  * math.sin(a3)),
        (lens_cx + blade_r_in  * math.cos(a2), lens_cy + blade_r_in  * math.sin(a2)),
    ]
    draw.polygon(pts, fill=(30, 50, 80, 230))

# lens reflection gleam
for ri, a in [(lens_r-62, 180), (lens_r-75, 140), (lens_r-85, 100)]:
    draw.ellipse([lens_cx-ri, lens_cy-ri, lens_cx+ri, lens_cy+ri],
                 outline=(50, 100, 160, a), width=2)

# bright center pupil with glow
for r in range(30, 0, -2):
    a = int(220 * (1 - r/30)**0.6)
    draw.ellipse([lens_cx-r, lens_cy-r, lens_cx+r, lens_cy+r],
                 fill=(0, 220, 255, a))
draw.ellipse([lens_cx-10, lens_cy-10, lens_cx+10, lens_cy+10],
             fill=WHITE + (255,))

# lens glint
draw.ellipse([lens_cx - lens_r + 18, lens_cy - lens_r + 18,
              lens_cx - lens_r + 36, lens_cy - lens_r + 36],
             fill=(255, 255, 255, 120))

# IR LEDs on camera body (left side cluster)
led_base_x = bx0 + bh//2 + 20
for i, (lx_off, ly_off) in enumerate([(-60, -55), (0, -65), (60, -55),
                                        (-60,  55), (0,  65), (60,  55)]):
    lx = led_base_x + lx_off + 100
    ly = cam_cy + ly_off
    draw.ellipse([lx-10, ly-10, lx+10, ly+10], fill=(20, 12, 12, 255))
    col = RED if i % 2 == 0 else (180, 30, 30)
    for gr in range(14, 0, -2):
        ga = int(80 * (1 - gr/14))
        draw.ellipse([lx-gr, ly-gr, lx+gr, ly+gr], fill=(255, 50, 50, ga))
    draw.ellipse([lx-5, ly-5, lx+5, ly+5], fill=RED+(255,))

# body panel lines / vents
for i in range(3):
    vx = led_base_x + 220 + i * 18
    draw.line([vx, by0+20, vx, by1-20], fill=(30, 50, 80, 180), width=3)

# ── targeting reticle overlay ─────────────────────────────────────────────────

# outer targeting ring
glow_ellipse(draw, cx, cy + 30, 440, 440, 5, CYAN)

# tick marks
for deg in range(0, 360, 10):
    rad = math.radians(deg)
    is_major = deg % 90 == 0
    is_mid   = deg % 30 == 0 and not is_major
    r_in  = 410 if is_major else (418 if is_mid else 424)
    w     = 5   if is_major else (4   if is_mid else 2)
    x0_ = cx + 440 * math.cos(rad)
    y0_ = cy + 30 + 440 * math.sin(rad)
    x1_ = cx + r_in * math.cos(rad)
    y1_ = cy + 30 + r_in * math.sin(rad)
    draw.line([x0_, y0_, x1_, y1_], fill=CYAN+(200,), width=w)

# crosshair arms (gap over camera)
gap = 160
arm_len = 430
for angle in [0, 90, 180, 270]:
    rad = math.radians(angle)
    glow_line(draw,
              cx + gap * math.cos(rad),       cy + 30 + gap * math.sin(rad),
              cx + arm_len * math.cos(rad),   cy + 30 + arm_len * math.sin(rad),
              4, CYAN)

# corner brackets
bkt_r = 300
bkt_len = 80
bkt_w = 7
for dx, dy in [(-1,-1),(1,-1),(-1,1),(1,1)]:
    bkx = cx + dx * bkt_r
    bky = cy + 30 + dy * bkt_r
    glow_line(draw, bkx, bky, bkx + dx*bkt_len, bky, bkt_w, CYAN)
    glow_line(draw, bkx, bky, bkx, bky + dy*bkt_len, bkt_w, CYAN)

# REC indicator dot (top-right)
rec_x, rec_y = cx + 320, cy - 330
for r in range(20, 0, -2):
    a = int(200 * (1 - r/20))
    draw.ellipse([rec_x-r, rec_y-r, rec_x+r, rec_y+r], fill=(255, 40, 40, a))
draw.ellipse([rec_x-9, rec_y-9, rec_x+9, rec_y+9], fill=RED+(255,))

img.save("/home/user/ApexSight/assets/icon.png", "PNG")
print("icon.png written")

# ── notification icon ─────────────────────────────────────────────────────────
notif = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
nd = ImageDraw.Draw(notif)
nc = 48
nd.ellipse([6, 6, 90, 90], outline=(255,255,255,255), width=4)
nd.ellipse([20, 20, 76, 76], outline=(255,255,255,180), width=2)
nd.line([nc, 8,  nc, 30], fill=(255,255,255,255), width=3)
nd.line([nc, 66, nc, 88], fill=(255,255,255,255), width=3)
nd.line([8,  nc, 30, nc], fill=(255,255,255,255), width=3)
nd.line([66, nc, 88, nc], fill=(255,255,255,255), width=3)
nd.ellipse([40, 40, 56, 56], fill=(255,255,255,255))
notif.save("/home/user/ApexSight/assets/notification-icon.png", "PNG")
print("notification-icon.png written")
