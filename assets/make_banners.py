# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "numpy"]
# ///
"""Баннеры бота: пиксельная мозаика своей формы у каждого экрана и одно чёрное слово шрифтом Waoki.

Запуск: uv run --script assets/make_banners.py [--mosaics КАТАЛОГ] [имя ...]
Результат: assets/banners/<имя>.jpg (1280x640). Всё считается кодом; повторный запуск даёт те же
файлы. С --mosaics рядом сохраняются исходные мозаики 64x32 (на холсте они растягиваются без
сглаживания), а в стандартный вывод идёт раскладка слов. Правила стиля — в assets/STYLE.md.
"""
import json
import sys
import zlib
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 640
GX, GY = 64, 32  # блоков по ширине и высоте; блок на баннере — 20x20 px
HERE = Path(__file__).parent
FONT = str(HERE / "Waoki.otf")
OUT = HERE / "banners"

INK = (10, 12, 10)
MAX_W, MAX_SIZE, ONE_LINE_MIN = 1040, 260, 150  # колонка слова, наибольший кегль и порог для одной строки
MIN_CONTRAST = 7.0  # каждый тон мозаики с чёрным словом должен давать не меньше


# --- формы поля: значение 0..1, самое светлое — там, где поле «сильнее» ---------------------------
# x идёт от 0 до 2 (ширина вдвое больше высоты), y — от 0 до 1, чтобы расстояния были круглыми.


def g(x, y, cx, cy, sx, sy):
    return np.exp(-(((x - cx) / sx) ** 2 + ((y - cy) / sy) ** 2))


def f_center(x, y):  # одно большое пятно в центре и два слабых по углам
    return g(x, y, 1, .5, .62, .42) + .5 * g(x, y, .2, .88, .4, .3) + .45 * g(x, y, 1.85, .14, .36, .3)


def f_stripes(x, y):  # диагональные полосы
    s = x * np.cos(np.radians(-28)) + y * np.sin(np.radians(-28))
    return .5 + .5 * np.sin(2 * np.pi * s * 1.15)


def f_layers(x, y):  # волнистые горизонтальные слои
    return .5 + .5 * np.sin(2 * np.pi * (y * 2.1 + .12 * np.sin(2 * np.pi * x * .9)))


def f_two(x, y):  # два пятна в разных углах
    return g(x, y, .5, .66, .52, .4) + g(x, y, 1.5, .34, .48, .36)


def f_rings(x, y):  # кольца вокруг смещённого центра
    d = np.hypot(x - 1.35, (y - .5) * 1.3)
    return .5 + .5 * np.cos(2 * np.pi * d * 1.3)


def f_three(x, y):  # три пятна в ряд
    return g(x, y, .42, .5, .3, .34) + 1.15 * g(x, y, 1, .5, .32, .44) + g(x, y, 1.58, .5, .3, .34)


def f_corner(x, y):  # четверть круга из левого нижнего угла и маленькое пятно напротив
    return np.exp(-(np.hypot(x, 1 - y) / .95) ** 2) + .55 * g(x, y, 1.85, .15, .3, .26)


def f_diamond(x, y):  # ромб
    return 1 - (np.abs(x - 1) * .8 + np.abs(y - .5) * 1.7)


def f_bubble(x, y):  # скруглённый прямоугольник, как реплика
    p = (np.abs(x - 1) / .82) ** 4 + (np.abs(y - .5) / .36) ** 4
    return 1 / (1 + p)


def f_wave(x, y):  # синусоида — росчерк
    return np.exp(-((y - (.5 + .2 * np.sin(2 * np.pi * x * .75))) / .17) ** 2)


def f_band(x, y):  # одна толстая наклонная полоса
    return np.exp(-((y - (.5 - .38 * (x - 1))) / .22) ** 2)


def f_swoosh(x, y):  # дуга вверх вправо, к концу сильнее
    return np.exp(-((y - (.82 - .52 * (x / 2) ** 1.15)) / .16) ** 2) * (.3 + .7 * x / 2)


def f_disc(x, y):  # круг и кольцо вокруг
    r = np.hypot(x - 1, y - .5)
    return np.exp(-(r / .36) ** 4) + .4 * np.exp(-((r - .62) / .05) ** 2)


def f_cross(x, y):  # крест из двух диагоналей
    return np.maximum(np.exp(-(((y - .5) - (x - 1) * .5) / .13) ** 2), np.exp(-(((y - .5) + (x - 1) * .5) / .13) ** 2))


def f_columns(x, y):  # вертикальные волнистые полосы
    return .5 + .5 * np.sin(2 * np.pi * (x * 1.7 + .15 * np.sin(2 * np.pi * y * 1.3)))


# имя: (форма, палитра от самого низкого значения к самому высокому, слово)
# Тона светлые: сверху вниз — насыщенный, акцент, основной, светлый, почти белый.
SPECS = {
    "menu": (f_center, ["#6FD27A", "#FFB04A", "#B9EF55", "#E2FA9A", "#F7FFD6"], "Предложка"),
    "rules": (f_stripes, ["#7CCBF2", "#FFD36B", "#A6E9D2", "#CFF3EC", "#F2FFFB"], "Правила"),
    "mine": (f_layers, ["#B79CFF", "#FF9CCB", "#D5C2FF", "#EBDDFF", "#FAF5FF"], "Мои заявки"),
    "media": (f_two, ["#FF9F7A", "#FFD95E", "#FFC49E", "#FFE6B8", "#FFF8E5"], "Работа"),
    "artist": (f_rings, ["#FF8FA3", "#FFC857", "#FFB3C0", "#FFD6DD", "#FFF2F4"], "Художник"),
    "chars": (f_three, ["#5ED6A4", "#F9E36B", "#A5F0C9", "#D4F9E2", "#F0FFF7"], "Братухи"),
    "artist_new": (f_corner, ["#4FD6D0", "#FFE066", "#9BEFE9", "#CBF8F5", "#EFFFFE"], "Новый художник"),
    "chars_new": (f_diamond, ["#9AA8FF", "#FFB3E6", "#BFC8FF", "#DCE1FF", "#F4F6FF"], "Новый братуха"),
    "caption": (f_bubble, ["#FFD24D", "#FF9F5A", "#FFE58A", "#FFF0B8", "#FFFBE6"], "Подпись"),
    "credit": (f_wave, ["#FF9EB5", "#FFD08A", "#FFC2D1", "#FFE0E8", "#FFF5F8"], "Автограф"),
    "edit": (f_band, ["#8FA5FF", "#7FE8F2", "#B9C6FF", "#DCE3FF", "#F3F6FF"], "Правка"),
    "sent": (f_swoosh, ["#7ACBFF", "#B8F0D8", "#A5DCFF", "#D2EEFF", "#F2FAFF"], "Отправлено"),
    "approved": (f_disc, ["#66DD88", "#C8F060", "#9BEBAF", "#CBF5D6", "#F0FFF4"], "Принято"),
    "rejected": (f_cross, ["#FF8F7E", "#FFC7A8", "#FFB0A3", "#FFD3CC", "#FFF1EE"], "Отклонено"),
    "reason": (f_columns, ["#FFB347", "#FF8F6B", "#FFD08A", "#FFE5BB", "#FFF6E6"], "Причина"),
}


def rgb(hexcolor):
    return tuple(int(hexcolor[i:i + 2], 16) for i in (1, 3, 5))


def luminance(c):
    def ch(v):
        v /= 255
        return v / 12.92 if v <= .03928 else ((v + .055) / 1.055) ** 2.4
    return .2126 * ch(c[0]) + .7152 * ch(c[1]) + .0722 * ch(c[2])


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + .05) / (lb + .05)


def mosaic(name):
    """Мозаика GXxGY: гладкое поле формы, дрожание границ и нарезка на пять тонов."""
    form, palette, _ = SPECS[name]
    rng = np.random.default_rng(zlib.crc32(name.encode()))
    yy, xx = np.mgrid[0:GY, 0:GX]
    x, y = xx / (GX - 1) * 2, yy / (GY - 1)
    f = form(x, y)
    f = (f - f.min()) / (f.max() - f.min())
    f = f + rng.normal(0, .035, f.shape)  # дрожание границ, как в образце
    bands = np.digitize(f, [.22, .42, .6, .78])
    colors = np.array([rgb(c) for c in palette], np.uint8)
    return Image.fromarray(colors[bands])


def layout(word, font_path=FONT):
    """Строки и кегль слова: крупно на всю колонку, длинные названия — в две строки."""
    def width(s, size):
        return ImageFont.truetype(font_path, 1000).getlength(s) / 1000 * size

    one = min(MAX_SIZE, MAX_W / (width(word, 1)))
    if one >= ONE_LINE_MIN or " " not in word:
        return [word], int(one)
    longest = max(width(w, 1) for w in word.split())
    return word.split(), int(min(MAX_SIZE, MAX_W / longest))


def render(name):
    word = SPECS[name][2]
    img = mosaic(name).resize((W, H), Image.NEAREST)
    lines, size = layout(word)
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(FONT, size)
    top = H / 2 - size * len(lines) / 2
    for i, ln in enumerate(lines):
        d.text((W / 2, top + size * (i + .5)), ln, font=f, fill=INK, anchor="mm")
    OUT.mkdir(exist_ok=True)
    img.save(OUT / f"{name}.jpg", quality=95, subsampling=0, optimize=True)


def check_palettes():
    bad = [(n, c, round(contrast(rgb(c), INK), 1)) for n, (_, pal, _) in SPECS.items() for c in pal
           if contrast(rgb(c), INK) < MIN_CONTRAST]
    if bad:
        sys.exit("Мало контраста с чёрным словом: %s" % bad)


if __name__ == "__main__":
    args = sys.argv[1:]
    mosaics = None
    if args[:1] == ["--mosaics"]:
        mosaics, args = Path(args[1]), args[2:]
        mosaics.mkdir(parents=True, exist_ok=True)
    check_palettes()
    sheet = {}
    for n in args or SPECS:
        render(n)
        sheet[n] = layout(SPECS[n][2])
        if mosaics:
            mosaic(n).save(mosaics / f"mosaic_{n}.png", optimize=True)
        print("ok", n, file=sys.stderr)
    if mosaics:
        print(json.dumps(sheet, ensure_ascii=False))
