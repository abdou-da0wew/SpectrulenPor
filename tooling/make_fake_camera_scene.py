#!/usr/bin/env python3
"""Generate a small lab-scene YUV4MPEG2 (.y4m) video for Chromium's fake camera
(--use-file-for-fake-video-capture) so in-browser Flutter web screenshots show
a realistic camera preview instead of a test pattern.

The Flutter camera preview requests a 1280x720 landscape stream and letterboxes
it with BoxFit.cover into a portrait area, so the visible band of the source
frame is roughly its CENTER ~530x720 strip. The whole scene is therefore
composed inside that center band."""

from PIL import Image, ImageDraw, ImageFilter
import math

W, H, FPS, FRAMES = 1280, 720, 30, 75
# scene band (visible after the preview crop)
BX0, BX1 = 380, 900
OUT = "/tmp/lab_scene.y4m"


def draw_frame(t: int) -> Image.Image:
    dx = int(4 * math.sin(t / 9.0))
    dy = int(3 * math.cos(t / 11.0))
    ox = (W - (BX1 - BX0)) // 2  # scene band offset

    img = Image.new("RGB", (W, H), (208, 202, 192))  # wall
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W, 190], fill=(196, 190, 180))
    d.rectangle([0, 190, W, H], fill=(172, 140, 104))  # wooden desk
    d.rectangle([0, 190, W, 200], fill=(158, 126, 92))

    def sx(x):  # scene x -> canvas x
        return x + ox + dx

    # window light patches (inside the visible band)
    d.rectangle([sx(20), 14 + dy, sx(200), 120 + dy], fill=(228, 224, 214))
    d.rectangle([sx(240), 14 + dy, sx(470), 120 + dy], fill=(222, 218, 208))

    # beaker with blue liquid (center-left of band)
    bx, by = sx(20), 300 + dy
    d.rounded_rectangle([bx, by, bx + 130, by + 210], 10, outline=(240, 240, 240), width=6)
    d.rounded_rectangle([bx + 6, by + 88, bx + 124, by + 204], 6, fill=(96, 148, 200))
    d.rectangle([bx + 6, by + 88, bx + 124, by + 108], fill=(120, 168, 216))
    for i in range(4):
        yy = by + 122 + i * 18
        d.line([bx + 20, yy, bx + 44, yy], fill=(235, 240, 245), width=2)

    # amber reagent bottle (center-right of band)
    rx, ry = sx(180), 330 + dy
    d.rounded_rectangle([rx, ry, rx + 100, ry + 170], 12, fill=(168, 118, 60))
    d.rounded_rectangle([rx + 4, ry + 10, rx + 96, ry + 160], 10, outline=(140, 96, 44), width=3)
    d.rectangle([rx + 34, ry - 26, rx + 66, ry + 8], fill=(90, 62, 30))
    d.rounded_rectangle([rx + 16, ry + 50, rx + 84, ry + 132], 4, fill=(224, 214, 196))
    d.line([rx + 24, ry + 74, rx + 76, ry + 74], fill=(120, 90, 50), width=3)
    d.line([rx + 24, ry + 92, rx + 64, ry + 92], fill=(120, 90, 50), width=3)

    # erlenmeyer flask (top of band)
    d.polygon([(sx(150), 180 + dy), (sx(182), 180 + dy), (sx(212), 236 + dy), (sx(120), 236 + dy)],
              outline=(238, 238, 238), width=5)
    d.ellipse([sx(120), 218 + dy, sx(212), 260 + dy], outline=(238, 238, 238), width=5)

    # notebook at the bottom of the band
    d.rounded_rectangle([sx(10), 520 + dy, sx(480), 626 + dy], 8, fill=(238, 236, 230))
    for i in range(5):
        yy = 540 + dy + i * 16
        d.line([sx(28), yy, sx(462), yy], fill=(190, 188, 180), width=2)

    # soft vignette + slight blur for a camera feel
    img = img.filter(ImageFilter.GaussianBlur(0.8))
    vig = Image.new("L", (W, H), 0)
    dv = ImageDraw.Draw(vig)
    dv.ellipse([-W // 3, -H // 3, W + W // 3, H + H // 3], fill=255)
    vig = vig.filter(ImageFilter.GaussianBlur(80))
    dark = Image.new("RGB", (W, H), (30, 26, 22))
    img = Image.composite(img, dark, vig)
    return img


def to_yuv420(img: Image.Image):
    ycbcr = img.convert("YCbCr")
    y, cb, cr = ycbcr.split()
    w2, h2 = W // 2, H // 2
    cb = cb.resize((w2, h2), Image.BOX)
    cr = cr.resize((w2, h2), Image.BOX)
    return y.tobytes(), cb.tobytes(), cr.tobytes()


def main() -> None:
    with open(OUT, "wb") as f:
        f.write(f"YUV4MPEG2 W{W} H{H} F{FPS}:1 Ip A1:1 C420jpeg\n".encode())
        for t in range(FRAMES):
            y, u, v = to_yuv420(draw_frame(t))
            f.write(b"FRAME\n")
            f.write(y)
            f.write(u)
            f.write(v)
    import os
    print(f"wrote {OUT}: {os.path.getsize(OUT) / 1e6:.1f} MB, {FRAMES} frames @{FPS}fps {W}x{H}")


if __name__ == "__main__":
    main()
