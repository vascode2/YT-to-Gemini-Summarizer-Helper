"""
Generate docs/workflow-demo.gif — clean instruction slides (white + red text).
Run: python scripts/generate_workflow_demo_gif.py
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

try:
    import imageio.v2 as imageio
except ImportError:
    raise SystemExit("pip install pillow imageio")

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "docs" / "workflow-demo.gif"

FONT_LG = FONT_MD = FONT_SM = ImageFont.load_default()

W, H = 720, 405
FPS = 5
HOLD = int(FPS * 3.5)

BG = "#ffffff"
RED = "#b71c1c"
RED_DIM = "#c62828"


def try_font(size: int) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    for name in ("segoeui.ttf", "arial.ttf", "calibri.ttf"):
        try:
            return ImageFont.truetype(name, size)
        except OSError:
            continue
    return ImageFont.load_default()


def blank() -> Image.Image:
    return Image.new("RGB", (W, H), BG)


def frame_border(d: ImageDraw.ImageDraw) -> None:
    d.rounded_rectangle((24, 18, W - 24, H - 18), radius=12, outline=RED, width=3)


def scene_title() -> Image.Image:
    im = blank()
    d = ImageDraw.Draw(im)
    frame_border(d)
    d.text((W // 2, 110), "CopyURL", fill=RED, font=FONT_LG, anchor="mm")
    d.text(
        (W // 2, 175),
        "YouTube thumbnail → Gemini summary",
        fill=RED_DIM,
        font=FONT_MD,
        anchor="mm",
    )
    d.text(
        (W // 2, 255),
        "Windows · Alt+A · AutoHotkey",
        fill=RED_DIM,
        font=FONT_SM,
        anchor="mm",
    )
    return im


def scene_hover() -> Image.Image:
    im = blank()
    d = ImageDraw.Draw(im)
    frame_border(d)
    d.text((W // 2, 120), "1", fill=RED, font=FONT_LG, anchor="mm")
    d.text((W // 2, 185), "Hover the video thumbnail", fill=RED, font=FONT_MD, anchor="mm")
    d.text((W // 2, 245), "on YouTube (extension on)", fill=RED_DIM, font=FONT_SM, anchor="mm")
    return im


def scene_hotkey() -> Image.Image:
    im = blank()
    d = ImageDraw.Draw(im)
    frame_border(d)
    d.text((W // 2, 120), "2", fill=RED, font=FONT_LG, anchor="mm")
    d.text((W // 2, 185), "Press Alt + Z", fill=RED, font=FONT_MD, anchor="mm")
    d.text(
        (W // 2, 245),
        "AutoHotkey copies the link, opens Gemini",
        fill=RED_DIM,
        font=FONT_SM,
        anchor="mm",
    )
    return im


def scene_gemini() -> Image.Image:
    im = blank()
    d = ImageDraw.Draw(im)
    frame_border(d)
    d.text((W // 2, 110), "3", fill=RED, font=FONT_LG, anchor="mm")
    d.text((W // 2, 175), "Message sent to Gemini", fill=RED, font=FONT_MD, anchor="mm")
    d.text(
        (W // 2, 235),
        "Summarize line + your YouTube URL",
        fill=RED_DIM,
        font=FONT_SM,
        anchor="mm",
    )
    d.text(
        (W // 2, 285),
        "(mouse is not moved — posted messages)",
        fill=RED_DIM,
        font=FONT_SM,
        anchor="mm",
    )
    return im


def scene_summary() -> Image.Image:
    im = blank()
    d = ImageDraw.Draw(im)
    frame_border(d)
    d.text((W // 2, 120), "4", fill=RED, font=FONT_LG, anchor="mm")
    d.text((W // 2, 185), "Read the summary in Gemini", fill=RED, font=FONT_MD, anchor="mm")
    d.text(
        (W // 2, 245),
        "Follow up in the same chat if you want",
        fill=RED_DIM,
        font=FONT_SM,
        anchor="mm",
    )
    return im


def main() -> None:
    global FONT_LG, FONT_MD, FONT_SM
    OUT.parent.mkdir(parents=True, exist_ok=True)
    FONT_LG = try_font(40)
    FONT_MD = try_font(26)
    FONT_SM = try_font(20)

    scenes = [
        scene_title(),
        scene_hover(),
        scene_hotkey(),
        scene_gemini(),
        scene_summary(),
    ]

    frames: list[Image.Image] = []
    for im in scenes:
        for _ in range(HOLD):
            frames.append(im.copy())
    for _ in range(HOLD // 2):
        frames.append(scenes[0].copy())

    # Few colors → minimal GIF dithering on GitHub
    imageio.mimsave(
        OUT,
        [f.convert("P", palette=Image.ADAPTIVE, colors=32) for f in frames],
        fps=FPS,
        loop=0,
    )
    print(f"Wrote {OUT} ({len(frames)} frames @ {FPS} fps)")


if __name__ == "__main__":
    main()
