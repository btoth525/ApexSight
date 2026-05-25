from PIL import Image, ImageDraw, ImageFont
import os

NAVY = (15, 23, 42)       # #0f172a
CYAN = (0, 180, 216)      # #00b4d8
WHITE = (255, 255, 255)
TRANSPARENT = (0, 0, 0, 0)

assets_dir = os.path.dirname(os.path.abspath(__file__))


def draw_camera(draw, cx, cy, size, color):
    """Draw a simple camera shape centered at (cx, cy) with given size."""
    body_w = int(size * 0.80)
    body_h = int(size * 0.55)
    body_r = int(size * 0.10)

    # Viewfinder bump on top
    bump_w = int(size * 0.25)
    bump_h = int(size * 0.12)
    bump_r = int(size * 0.06)

    # Lens
    lens_r = int(size * 0.18)

    # Draw body (rounded rectangle)
    bx0 = cx - body_w // 2
    by0 = cy - body_h // 2
    bx1 = cx + body_w // 2
    by1 = cy + body_h // 2
    draw.rounded_rectangle([bx0, by0, bx1, by1], radius=body_r, fill=color)

    # Draw bump on top-left area of body
    bump_cx = cx - body_w // 4
    bump_y0 = by0 - bump_h
    bump_y1 = by0
    draw.rounded_rectangle(
        [bump_cx - bump_w // 2, bump_y0, bump_cx + bump_w // 2, bump_y1],
        radius=bump_r,
        fill=color,
    )

    # Draw lens circle (cut out with NAVY, then draw a smaller circle)
    outer_r = lens_r
    inner_r = int(lens_r * 0.65)
    # Outer lens ring
    draw.ellipse(
        [cx - outer_r, cy - outer_r, cx + outer_r, cy + outer_r],
        fill=color if color == WHITE else (0, 0, 0, 0),
        outline=color if color != WHITE else None,
    )


def draw_camera_icon(draw, cx, cy, size, color, bg_color=None):
    """Draw camera: body + bump + lens outline."""
    body_w = int(size * 0.80)
    body_h = int(size * 0.55)
    body_r = int(size * 0.10)

    bump_w = int(size * 0.26)
    bump_h = int(size * 0.13)
    bump_r = int(size * 0.06)

    lens_r = int(size * 0.20)
    inner_r = int(size * 0.12)

    bx0 = cx - body_w // 2
    by0 = cy - body_h // 2
    bx1 = cx + body_w // 2
    by1 = cy + body_h // 2

    # Body
    draw.rounded_rectangle([bx0, by0, bx1, by1], radius=body_r, fill=color)

    # Bump
    bump_cx = cx - body_w // 5
    draw.rounded_rectangle(
        [bump_cx - bump_w // 2, by0 - bump_h, bump_cx + bump_w // 2, by0 + 2],
        radius=bump_r,
        fill=color,
    )

    # Lens outer circle (cut out with bg color)
    if bg_color is not None:
        draw.ellipse(
            [cx - lens_r, cy - lens_r, cx + lens_r, cy + lens_r],
            fill=bg_color,
        )
    # Lens inner ring
    draw.ellipse(
        [cx - inner_r, cy - inner_r, cx + inner_r, cy + inner_r],
        fill=color,
    )


# ─── 1. icon.png ────────────────────────────────────────────────────────────
W, H = 1024, 1024
img = Image.new("RGB", (W, H), NAVY)
draw = ImageDraw.Draw(img)

camera_size = 480
draw_camera_icon(draw, W // 2, H // 2, camera_size, CYAN, bg_color=NAVY)

icon_path = os.path.join(assets_dir, "icon.png")
img.save(icon_path)
print(f"Saved {icon_path}")


# ─── 2. splash.png ──────────────────────────────────────────────────────────
SW, SH = 1284, 2778
splash = Image.new("RGB", (SW, SH), NAVY)
draw = ImageDraw.Draw(splash)

# Try to load a font, fall back to default
try:
    font_title = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 180)
    font_sub   = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 90)
except Exception:
    font_title = ImageFont.load_default()
    font_sub   = ImageFont.load_default()

cx = SW // 2
cy = SH // 2

# Camera icon above text
cam_size = 260
draw_camera_icon(draw, cx, cy - 330, cam_size, CYAN, bg_color=NAVY)

# "Frigate" title
title = "Frigate"
bbox = draw.textbbox((0, 0), title, font=font_title)
tw = bbox[2] - bbox[0]
th = bbox[3] - bbox[1]
draw.text((cx - tw // 2, cy - th // 2 + 20), title, fill=WHITE, font=font_title)

# "NVR" subtitle
sub = "NVR"
sbbox = draw.textbbox((0, 0), sub, font=font_sub)
sw2 = sbbox[2] - sbbox[0]
draw.text((cx - sw2 // 2, cy + th // 2 + 40), sub, fill=CYAN, font=font_sub)

splash_path = os.path.join(assets_dir, "splash.png")
splash.save(splash_path)
print(f"Saved {splash_path}")


# ─── 3. notification-icon.png ───────────────────────────────────────────────
NW, NH = 96, 96
notif = Image.new("RGBA", (NW, NH), TRANSPARENT)
draw = ImageDraw.Draw(notif)

draw_camera_icon(draw, NW // 2, NH // 2, 76, WHITE, bg_color=TRANSPARENT)

notif_path = os.path.join(assets_dir, "notification-icon.png")
notif.save(notif_path)
print(f"Saved {notif_path}")

print("Done.")
