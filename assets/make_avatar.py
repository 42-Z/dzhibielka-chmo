# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "numpy"]
# ///
"""Аватарка бота: пиксельная 🤙 в чёрном контуре на мозаике из колец.

Запуск: uv run --script assets/make_avatar.py
Результат: assets/avatar.jpg (640x640, JPG — так требует Bot API для setMyProfilePhoto).
Сетка та же, что у баннеров: блок 20x20 px; рука 22x22 блока, вокруг неё контур в один блок.
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

SIZE, CELL = 640, 20
GRID = SIZE // CELL  # 32 блока
HAND = 22            # блоков в стороне квадрата, в который вписана рука
OUT = Path(__file__).parent / "avatar.jpg"

INK = (10, 12, 10)
BG = ["#7FB6FF", "#A7B8FF", "#C2CBFF", "#DDE2FF", "#F4F6FF"]  # холодные тона: тёплая рука на них выделяется
SKIN = {"base": (255, 211, 74), "shade": (245, 165, 36), "deep": (194, 106, 18), "light": (255, 240, 168)}

# Рука в координатах эмодзи (квадрат 512x512, y вниз): контур каждой части.
PALM = [(25, 225), (100, 215), (150, 170), (215, 155), (340, 165), (350, 395), (240, 425), (100, 402), (25, 402)]
THUMB = [(215, 165), (222, 40), (235, 8), (262, 2), (285, 20), (293, 80), (288, 168)]
FINGERS = [(335, 172, 440, 250), (335, 252, 455, 330), (335, 332, 440, 402)]  # x0, y0, x1, y1 с закруглением справа
PINKY = [(345, 392), (400, 400), (490, 450), (506, 488), (480, 514), (430, 504), (345, 452)]
DIVIDERS = [(338, 250, 440, 258), (338, 330, 450, 338)]  # тёмные линии между пальцами


def rgb(h):
    return tuple(int(h[i:i + 2], 16) for i in (1, 3, 5))


def raster(draw_fn):
    """Рисует в четырёхкратном размере и берёт блок целиком, если закрашена хотя бы половина."""
    n = HAND * 4
    im = Image.new("L", (n, n), 0)
    d = ImageDraw.Draw(im)
    draw_fn(d, n / 512)
    a = np.asarray(im, np.float32).reshape(HAND, 4, HAND, 4).mean(axis=(1, 3)) / 255
    return a >= .5


def shapes():
    def silhouette(d, k):
        d.polygon([(x * k, y * k) for x, y in PALM], fill=255)
        d.polygon([(x * k, y * k) for x, y in THUMB], fill=255)
        d.polygon([(x * k, y * k) for x, y in PINKY], fill=255)
        for x0, y0, x1, y1 in FINGERS:
            d.rounded_rectangle((x0 * k, y0 * k, x1 * k, y1 * k), radius=(y1 - y0) * k / 2.4, fill=255)

    def fingers(d, k):
        for x0, y0, x1, y1 in FINGERS:
            d.rounded_rectangle((x0 * k, y0 * k, x1 * k, y1 * k), radius=(y1 - y0) * k / 2.4, fill=255)

    def lines(d, k):
        for x0, y0, x1, y1 in DIVIDERS:
            d.rectangle((x0 * k, y0 * k, x1 * k, y1 * k), fill=255)

    return raster(silhouette), raster(fingers), raster(lines)


def hand_layer():
    """Пиксельная рука: цвет каждого блока (или None) в квадрате HAND x HAND."""
    sil, fing, lines = shapes()
    cells = np.full((HAND, HAND), None, object)
    for y in range(HAND):
        for x in range(HAND):
            if not sil[y, x]:
                continue
            below = y + 1 < HAND and sil[y + 1, x]
            right = x + 1 < HAND and sil[y, x + 1]
            cells[y, x] = SKIN["base"]
            if fing[y, x] or not below or (y < 8 and not right):  # пальцы, нижний край, правый край большого пальца
                cells[y, x] = SKIN["shade"]
            if lines[y, x]:
                cells[y, x] = SKIN["deep"]
    return cells


def background(rng):
    """Мозаика 32x32: кольца вокруг центра, как волны от звонка."""
    yy, xx = np.mgrid[0:GRID, 0:GRID]
    d = np.hypot(xx - (GRID - 1) / 2, yy - (GRID - 1) / 2) / (GRID / 2)
    f = .5 + .5 * np.cos(2 * np.pi * d * 2.6)
    f = (f - f.min()) / (f.max() - f.min()) + rng.normal(0, .035, f.shape)
    bands = np.digitize(f, [.22, .42, .6, .78])
    return np.array([rgb(c) for c in BG], np.uint8)[bands]


def main():
    rng = np.random.default_rng(42)
    canvas = np.zeros((GRID, GRID, 3), np.uint8)
    canvas[:] = background(rng)

    hand = hand_layer()
    # центр руки по её фигуре, чтобы она ровно легла в круглую обрезку Telegram
    ys, xs = np.nonzero(hand != None)  # noqa: E711
    oy = (GRID - (ys.max() - ys.min() + 1)) // 2 - ys.min()
    ox = (GRID - (xs.max() - xs.min() + 1)) // 2 - xs.min()
    filled = np.zeros((GRID, GRID), bool)
    for y, x in zip(ys, xs):
        filled[y + oy, x + ox] = True
    # контур в один блок, кроме углов
    outline = np.zeros_like(filled)
    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        outline |= np.roll(np.roll(filled, dy, 0), dx, 1)
    outline &= ~filled
    canvas[outline] = INK
    for y, x in zip(ys, xs):
        canvas[y + oy, x + ox] = hand[y, x]

    img = Image.fromarray(canvas).resize((SIZE, SIZE), Image.NEAREST)
    img.save(OUT, quality=95, subsampling=0, optimize=True)
    # круглая обрезка Telegram: проверяем, что рука с контуром целиком в круге
    cy, cx = np.nonzero(filled | outline)
    far = np.hypot((cx + .5) * CELL - SIZE / 2, (cy + .5) * CELL - SIZE / 2).max()
    print(f"ok {OUT.name}, самая дальняя точка {far:.0f}px от центра (круг {SIZE // 2}px)")


main()
