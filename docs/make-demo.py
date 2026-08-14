#!/usr/bin/env python3
"""Render docs/demo.gif -- a terminal session showing the two scripts that matter.

The transcript below is real output, with the device serial masked. Deliberately a
terminal recording rather than a screen recording: a capture of the phone itself would
put a home screen, notifications and app list into a public repo, and the point of this
project is the tooling, not the mirror.

    python3 docs/make-demo.py
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

W, H = 900, 470
PAD, LH, FS = 26, 29, 18
BG, BAR = "#0d1117", "#161b22"
FG, DIM, GREEN, CYAN, RED = "#e6edf3", "#7d8590", "#3fb950", "#58a6ff", "#f85149"

# Static regular weights only. A variable font here renders at its default Thin axis,
# which is illegible as light-on-dark terminal text at this size.
FONTS = [
    "/usr/share/fonts/adwaita-mono-fonts/AdwaitaMono-Regular.ttf",
    "/usr/share/fonts/liberation-mono-fonts/LiberationMono-Regular.ttf",
    str(Path.home() / ".local/share/fonts/AgaveNerdFontMono-Regular.ttf"),
]


def load_font(size):
    for path in FONTS:
        if Path(path).exists():
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


FONT, FONT_SM = load_font(FS), load_font(FS - 4)

# (kind, text) -- 'cmd' types out one character at a time, everything else appears whole.
SCRIPT = [
    ("comment", "# the phone's display is dead. the laptop still gets in."),
    ("cmd",     "./s25-unlock.sh"),
    ("out",     "[unlock] device=••••••••••• via USB"),   # serial fully masked
    ("ok",      "[unlock] OK: unlocked (com.sec.android.app.launcher)"),
    ("blank",   ""),
    ("comment", "# an app lock. renders as a solid black rectangle in the mirror."),
    ("cmd",     "./s25-tap.sh -c"),
    ("out",     "  * Use PIN                                  tap 540,1491"),
    ("blank",   ""),
    ("comment", "# FLAG_SECURE blocks screen capture, not the accessibility tree."),
    ("cmd",     "./s25-tap.sh \"Use PIN\""),
    ("ok",      "[tap] 'Use PIN' at 540,1491"),
    ("out",     "[tap] now focused: BiometricPromptRoot"),
    ("ok",      "[tap] unlocked — no screen required"),
]

COLOR = {"comment": DIM, "out": FG, "ok": GREEN, "err": RED, "cmd": FG, "blank": FG}


def render(lines, typing=None):
    """lines: finished rows. typing: (text, n_chars) currently being typed."""
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)

    d.rectangle([0, 0, W, 34], fill=BAR)
    for i, c in enumerate(("#ff5f57", "#febc2e", "#28c840")):
        d.ellipse([PAD + i * 20, 12, PAD + i * 20 + 11, 23], fill=c)
    d.text((W // 2 - 90, 9), "dead-screen-android", font=FONT_SM, fill=DIM)

    y = 34 + PAD
    for kind, text in lines:
        if kind == "cmd":
            d.text((PAD, y), "$", font=FONT, fill=GREEN)
            d.text((PAD + 18, y), text, font=FONT, fill=FG)
        else:
            d.text((PAD, y), text, font=FONT, fill=COLOR[kind])
        y += LH

    if typing:
        text, n = typing
        d.text((PAD, y), "$", font=FONT, fill=GREEN)
        d.text((PAD + 18, y), text[:n], font=FONT, fill=FG)
        cx = PAD + 18 + d.textlength(text[:n], font=FONT)
        d.rectangle([cx + 2, y + 2, cx + 11, y + FS + 4], fill=CYAN)
    return img


frames, durations = [], []
shown = []
for kind, text in SCRIPT:
    if kind == "cmd":
        for n in range(0, len(text) + 1, 2):      # 2 chars per frame keeps the GIF small
            frames.append(render(shown, (text, n)))
            durations.append(45)
        frames.append(render(shown, (text, len(text))))
        durations.append(350)                     # beat before the command "runs"
    shown.append((kind, text))
    frames.append(render(shown))
    durations.append(90 if kind == "blank" else 620)

durations[-1] = 2600                              # hold the final frame

out = Path(__file__).parent / "demo.gif"
frames[0].save(out, save_all=True, append_images=frames[1:],
               duration=durations, loop=0, optimize=True)
print(f"{out}  {out.stat().st_size / 1024:.0f} KB  {len(frames)} frames")
