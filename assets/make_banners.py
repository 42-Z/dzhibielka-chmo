# /// script
# requires-python = ">=3.12"
# dependencies = ["pillow", "numpy"]
# ///
"""Баннеры бота: каждый экран — почтовая марка номиналом 42.

Запуск: uv run --script assets/make_banners.py [имя ...]
Результат: assets/banners/<имя>.jpg (1280x640). Всё рисуется кодом, надписи — шрифтом
Waoki.otf; случайность задана зерном от имени баннера, поэтому повторный запуск даёт
те же файлы. Правила стиля описаны в assets/STYLE.md.
"""
import math
import sys
import zlib
from contextlib import contextmanager
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

W, H, SS = 1280, 640, 3  # итоговый размер и множитель сглаживания
HERE = Path(__file__).parent
FONT = str(HERE / "Waoki.otf")
OUT = HERE / "banners"

INK = (29, 26, 34)
PAPER = (243, 233, 210)
VERMILION = (216, 67, 44)
MUSTARD = (233, 174, 46)
TEAL = (42, 111, 105)
PLUM = (85, 48, 94)
SKY = (178, 214, 206)  # светлая бирюза: небо, конверты

LW = 7.5  # толщина линии эмблем (пиксели итогового размера)
MISS = (7, 6)  # смещение цветной заливки относительно линии, как при плохой приводке
STAMP = (36, 36, 1244, 604)  # марка на цветном поле


def px(v):
    return int(round(v * SS))


def layer():
    return Image.new("RGBA", (W * SS, H * SS), (0, 0, 0, 0))


def font(size):
    return ImageFont.truetype(FONT, px(size))


# --- аффинные преобразования: (xx, xy, x0, yx, yy, y0) ---------------------------------


def m_mul(a, b):
    return (
        a[0] * b[0] + a[1] * b[3], a[0] * b[1] + a[1] * b[4], a[0] * b[2] + a[1] * b[5] + a[2],
        a[3] * b[0] + a[4] * b[3], a[3] * b[1] + a[4] * b[4], a[3] * b[2] + a[4] * b[5] + a[5],
    )


def m_move(dx, dy):
    return (1, 0, dx, 0, 1, dy)


def m_scale(k):
    return (k, 0, 0, 0, k, 0)


def m_turn(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return (c, -s, 0, s, c, 0)


# --- геометрия -------------------------------------------------------------------------


def arc(cx, cy, rx, ry, a0, a1, n=None):
    """Точки дуги эллипса; углы в градусах: 0 — вправо, растут по часовой (y вниз)."""
    n = n or max(8, int(abs(a1 - a0) / 4))
    return [
        (cx + rx * math.cos(math.radians(a0 + (a1 - a0) * i / n)),
         cy + ry * math.sin(math.radians(a0 + (a1 - a0) * i / n)))
        for i in range(n + 1)
    ]


def ellipse_pts(cx, cy, rx, ry):
    return arc(cx, cy, rx, ry, 0, 360, 72)[:-1]


def rrect_pts(x0, y0, x1, y1, r):
    r = min(r, (x1 - x0) / 2, (y1 - y0) / 2)
    return (arc(x1 - r, y0 + r, r, r, -90, 0) + arc(x1 - r, y1 - r, r, r, 0, 90)
            + arc(x0 + r, y1 - r, r, r, 90, 180) + arc(x0 + r, y0 + r, r, r, 180, 270))


def smooth(pts, n=10):
    """Замкнутая кривая Катмулла—Рома через точки."""
    out, m = [], len(pts)
    for i in range(m):
        p0, p1, p2, p3 = pts[(i - 1) % m], pts[i], pts[(i + 1) % m], pts[(i + 2) % m]
        for j in range(n):
            t = j / n
            out.append(tuple(
                0.5 * (2 * p1[k] + (-p0[k] + p2[k]) * t + (2 * p0[k] - 5 * p1[k] + 4 * p2[k] - p3[k]) * t * t
                       + (-p0[k] + 3 * p1[k] - 3 * p2[k] + p3[k]) * t ** 3) for k in (0, 1)))
    return out


def scallop(cx, cy, r, bumps, depth):
    return [
        (cx + (r + depth * math.cos(bumps * math.radians(a))) * math.cos(math.radians(a)),
         cy + (r + depth * math.cos(bumps * math.radians(a))) * math.sin(math.radians(a)))
        for a in range(0, 360, 2)
    ]


def star(cx, cy, r_out, r_in, n):
    pts = []
    for i in range(2 * n):
        r = r_out if i % 2 == 0 else r_in
        a = math.radians(-90 + 180 * i / n)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def wave(x0, x1, y, amp, length, n=80):
    return [(x0 + (x1 - x0) * i / n, y + amp * math.sin(2 * math.pi * (x0 + (x1 - x0) * i / n) / length))
            for i in range(n + 1)]


# --- эмблема: цветная заливка со смещением и линия чернилами поверх -------------------------


class Art:
    def __init__(self, cx, cy, k=1.0, rot=0.0):
        self.fill, self.ink = layer(), layer()
        self.df, self.di = ImageDraw.Draw(self.fill), ImageDraw.Draw(self.ink)
        self.m = m_mul(m_move(cx, cy), m_mul(m_turn(rot), m_scale(k)))
        self.k = k
        self.stack = []

    @contextmanager
    def at(self, dx=0, dy=0, rot=0, k=1.0, pivot=(0, 0)):
        """Вложенное преобразование: масштаб и поворот вокруг pivot, затем сдвиг."""
        self.stack.append((self.m, self.k))
        local = m_mul(m_move(dx + pivot[0], dy + pivot[1]),
                      m_mul(m_turn(rot), m_mul(m_scale(k), m_move(-pivot[0], -pivot[1]))))
        self.m = m_mul(self.m, local)
        self.k *= k
        try:
            yield
        finally:
            self.m, self.k = self.stack.pop()

    def tp(self, p):
        m = self.m
        return (px(m[0] * p[0] + m[1] * p[1] + m[2]), px(m[3] * p[0] + m[4] * p[1] + m[5]))

    def stroke(self, pts, w, color, closed):
        r = px(w * self.k) / 2
        P = [self.tp(p) for p in pts]
        if len(P) > 1:
            self.di.line(P + [P[0]] if closed else P, fill=color, width=int(round(2 * r)))
        for x, y in P:
            self.di.ellipse((x - r, y - r, x + r, y + r), fill=color)

    def poly(self, pts, fill=None, w=LW, color=INK, closed=True):
        if fill is not None:
            self.df.polygon([self.tp(p) for p in pts], fill=fill)
        if w:
            self.stroke(pts, w, color, closed)

    def line(self, pts, w=LW, color=INK):
        self.stroke(pts, w, color, False)

    def rrect(self, x0, y0, x1, y1, r, fill=None, w=LW, color=INK):
        self.poly(rrect_pts(x0, y0, x1, y1, r), fill, w, color)

    def ellipse(self, cx, cy, rx, ry=None, fill=None, w=LW, color=INK):
        self.poly(ellipse_pts(cx, cy, rx, ry or rx), fill, w, color)

    def dot(self, cx, cy, d, color=INK):
        """Точка диаметром d, нарисованная линией (без смещения заливки)."""
        self.stroke([(cx, cy)], d, color, False)

    def text(self, xy, s, size, color=INK, anchor="mm"):
        ang = -math.degrees(math.atan2(self.m[3], self.m[0]))
        tile = layer()
        x, y = self.tp(xy)
        ImageDraw.Draw(tile).text((x, y), s, font=font(size * self.k), fill=color, anchor=anchor)
        if abs(ang) > 0.01:
            tile = tile.rotate(ang, center=(x, y), resample=Image.BICUBIC)
        self.ink.alpha_composite(tile)

    @contextmanager
    def clip(self, pts):
        """Линии, нарисованные в блоке, обрезаются по многоугольнику pts."""
        main, main_d = self.ink, self.di
        tmp = layer()
        self.ink, self.di = tmp, ImageDraw.Draw(tmp)
        try:
            yield
        finally:
            mask = Image.new("L", tmp.size, 0)
            ImageDraw.Draw(mask).polygon([self.tp(p) for p in pts], fill=255)
            tmp.putalpha(ImageChops.multiply(tmp.getchannel("A"), mask))
            self.ink, self.di = main, main_d
            main.alpha_composite(tmp)


# --- эмблемы экранов ---------------------------------------------------------------------


def e_booth(a, ac):
    """Исповедальня с подглядывающими глазами: меню."""
    a.poly([(-175, -118), (0, -205), (175, -118)], fill=MUSTARD)
    a.rrect(-150, -118, 150, 185, 8, fill=ac)
    arch = [(-84, 52)] + arc(0, -42, 84, 84, 180, 360) + [(84, 52)]
    a.poly(arch, fill=PLUM, w=0)
    for x in (-33, 33):
        a.ellipse(x, -34, 25, 29, fill=PAPER, w=5)
        a.dot(x + 5, -30, 21)
    with a.clip(arch):
        for t in range(-260, 260, 46):
            a.line([(t, -150), (t + 210, 70)], w=3.4, color=MUSTARD)
            a.line([(t + 210, -150), (t, 70)], w=3.4, color=MUSTARD)
    a.poly(arch, w=LW)
    a.rrect(-84, 82, 84, 168, 6, fill=None, w=5.5)
    a.dot(0, 118, 15)
    a.poly([(-5, 120), (5, 120), (9, 150), (-9, 150)], fill=INK, w=0)
    a.text((0, -150), "42", 54)


def e_rules(a, ac):
    """Планшет с отметками: правила."""
    with a.at(rot=-6):
        a.rrect(-122, -168, 122, 172, 18, fill=ac)
        a.rrect(-96, -132, 96, 148, 8, fill=PAPER, w=5.5)
        a.rrect(-52, -192, 52, -140, 14, fill=PLUM)
        for i, y in enumerate((-82, -12, 58)):
            a.ellipse(-62, y, 15, fill=SKY, w=5)
            a.line([(-70, y + 1), (-63, y + 8), (-52, y - 8)], w=5)
            a.line([(-30, y), (66 - 22 * (i % 2), y)], w=11)
        a.line([(-72, 112), (60, 112)], w=5)


def envelope(a, x, y, w, h, color, rot=0.0):
    with a.at(dx=x, dy=y, rot=rot):
        a.rrect(-w / 2, -h / 2, w / 2, h / 2, 10, fill=color)
        a.line([(-w / 2 + 5, -h / 2 + 5), (0, 6), (w / 2 - 5, -h / 2 + 5)], w=6)
        a.line([(-w / 2 + 6, h / 2 - 6), (-w / 6, -2)], w=5)
        a.line([(w / 2 - 6, h / 2 - 6), (w / 6, -2)], w=5)


def e_letters(a, ac):
    """Стопка писем: «Мои заявки»."""
    envelope(a, -42, -62, 270, 172, MUSTARD, -13)
    envelope(a, 38, -10, 270, 172, SKY, 8)
    envelope(a, -6, 62, 270, 172, ac, -3)
    with a.at(dx=88, dy=30, rot=-3):
        a.rrect(-30, -34, 30, 34, 4, fill=PAPER, w=4.5)
        a.poly(star(0, 0, 18, 8, 5), fill=VERMILION, w=3.5)


def e_picture(a, ac):
    """Рамка с пейзажем: новая работа."""
    with a.at(rot=4):
        a.rrect(-156, -112, 156, 120, 10, fill=PAPER)
        a.rrect(-128, -86, 128, 94, 4, fill=MUSTARD, w=5.5)
        a.ellipse(62, -34, 28, fill=ac, w=5)
        a.poly([(-128, 94), (-52, -22), (6, 52), (48, -2), (128, 94)], fill=TEAL, w=5.5)
        a.poly([(-52, -22), (-30, 6), (-52, 10), (-70, 4)], fill=None, w=0)
        a.ellipse(0, -126, 17, fill=ac, w=5.5)
        a.line([(0, -112), (0, -100)], w=5.5)


def palette(a, ac, k=1.0):
    with a.at(k=k):
        body = smooth([(-172, 8), (-146, -84), (-48, -134), (62, -128), (150, -74), (172, 12),
                       (120, 92), (28, 116), (-18, 78), (-72, 98), (-140, 82)])
        a.poly(body, fill=MUSTARD)
        a.ellipse(-96, 30, 21, fill=PAPER, w=5.5)
        for x, y, c in ((-60, -60, ac), (10, -86, TEAL), (86, -52, PLUM), (110, 22, SKY), (40, 28, PAPER)):
            a.ellipse(x, y, 22, fill=c, w=5)


def brush(a, ac, x, y, rot):
    with a.at(dx=x, dy=y, rot=rot):
        a.rrect(-13, -150, 13, 30, 10, fill=ac, w=6)
        a.rrect(-15, 30, 15, 74, 3, fill=PAPER, w=6)
        a.line([(-15, 44), (15, 44)], w=4)
        a.line([(-15, 58), (15, 58)], w=4)
        a.poly([(-15, 74), (15, 74), (13, 118), (0, 150), (-13, 118)], fill=PLUM, w=6)


def e_palette(a, ac):
    palette(a, ac)
    brush(a, ac, 70, 24, 38)


def e_palette_new(a, ac):
    with a.at(dx=-20, dy=22):
        palette(a, ac, 0.88)
    a.ellipse(112, -108, 58, fill=ac)
    a.line([(112, -136), (112, -80)], w=15, color=PAPER)
    a.line([(84, -108), (140, -108)], w=15, color=PAPER)


def hero(a, x, y, k, body, hair, kind):
    with a.at(dx=x, dy=y, k=k):
        a.poly([(-66, 140), (-60, 52)] + arc(0, 52, 60, 34, 180, 360) + [(60, 52), (66, 140)], fill=body)
        a.ellipse(0, 0, 58, 62, fill=PAPER)
        if kind == 0:  # ёжик
            a.poly([(-58, -8), (-62, -50), (-36, -32), (-30, -78), (-6, -52), (12, -86), (30, -52), (52, -70), (56, -28),
                    (60, -8), (36, -40), (0, -34), (-30, -34)], fill=hair)
        elif kind == 1:  # чёлка
            a.poly(arc(0, 0, 62, 66, 180, 360) + [(60, -14), (30, -30), (-4, -14), (-28, -34), (-60, -12)], fill=hair)
        else:  # пучок
            a.poly(arc(0, 0, 61, 65, 190, 350), fill=hair)
            a.ellipse(0, -78, 22, fill=hair)
        a.dot(-21, 6, 12)
        a.dot(21, 6, 12)
        a.line(arc(0, 24, 20, 14, 20, 160), w=5.5)


def e_heroes(a, ac):
    hero(a, -128, 22, 0.78, TEAL, PLUM, 2)
    hero(a, 128, 22, 0.78, MUSTARD, VERMILION, 1)
    hero(a, 0, 0, 1.0, ac, INK, 0)


def e_hero_new(a, ac):
    hero(a, -24, 6, 1.1, ac, INK, 0)
    a.ellipse(116, -112, 56, fill=VERMILION)
    a.line([(116, -138), (116, -86)], w=15, color=PAPER)
    a.line([(90, -112), (142, -112)], w=15, color=PAPER)


def e_bubble(a, ac):
    """Реплика: подпись к работе."""
    a.poly([(-70, 56), (-104, 150), (8, 60)], fill=ac)
    a.rrect(-158, -112, 158, 74, 44, fill=ac)
    for y, x1 in ((-58, 98), (-14, 118), (30, 62)):
        a.line([(-104, y), (x1, y)], w=15, color=PAPER)
    a.line([(-70, 56), (-104, 150), (8, 60)], w=LW)


def e_autograph(a, ac):
    """Карточка с автографом: подпись отправителя."""
    with a.at(rot=-5):
        a.rrect(-156, -104, 156, 96, 14, fill=SKY)
        a.line([(-114, 44), (66, 44)], w=5)
        a.line([(-114, 20), (-96, 20)], w=5)
        sig = [(-104, 20), (-80, -40), (-62, 30), (-50, -50), (-38, 28), (-6, -20), (6, 28), (22, -14), (40, 18),
               (70, -26), (100, 10)]
        a.line(smooth(sig, 8)[:-8], w=7, color=ac)
        a.poly(star(112, -62, 24, 10, 5), fill=MUSTARD, w=4.5)
    with a.at(dx=88, dy=94, rot=38):
        a.poly([(-18, -120), (18, -120), (22, -30), (0, 40), (-22, -30)], fill=INK, w=5)
        a.line([(0, -26), (0, 36)], w=4, color=PAPER)
        a.dot(0, -12, 11, PAPER)


def e_pencil(a, ac):
    with a.at(dx=10, dy=-10, rot=-35):
        a.rrect(-150, -34, 96, 34, 6, fill=MUSTARD)
        a.line([(-150, -8), (96, -8)], w=4.5)
        a.line([(-150, 14), (96, 14)], w=4.5)
        a.poly([(-150, -34), (-230, 0), (-150, 34)], fill=PAPER)
        a.poly([(-206, -12), (-230, 0), (-206, 12)], fill=INK, w=3)
        a.rrect(96, -34, 122, 34, 3, fill=SKY)
        a.rrect(122, -34, 176, 34, 14, fill=ac)
    for x, y, r in ((-150, 130, 20), (-96, 150, 14), (-30, 136, 10)):
        a.poly(arc(x, y, r, r * 0.6, 200, 520), fill=None, w=4.5, closed=False)


def e_seal(a, ac):
    """Печать с галочкой: принято."""
    a.poly([(-70, 80), (-112, 196), (-50, 164), (-14, 202), (20, 90)], fill=VERMILION, w=6)
    a.poly([(70, 80), (112, 196), (50, 164), (14, 202), (-20, 90)], fill=MUSTARD, w=6)
    a.poly(scallop(0, -16, 140, 14, 9), fill=ac)
    a.ellipse(0, -16, 106, fill=None, w=5, color=PAPER)
    a.line([(-56, -14), (-18, 28), (60, -62)], w=24)
    a.line([(-56, -14), (-18, 28), (60, -62)], w=11, color=PAPER)


def e_reject(a, ac):
    """Штамп с крестом: отклонено."""
    with a.at(rot=-9):
        a.rrect(-156, -110, 156, 110, 18, fill=None, w=14, color=ac)
        a.rrect(-136, -90, 136, 90, 10, fill=None, w=5, color=ac)
        a.line([(-84, -52), (84, 52)], w=28, color=ac)
        a.line([(84, -52), (-84, 52)], w=28, color=ac)


def e_sent(a, ac):
    """Запечатанный конверт с дорожкой: заявка отправлена."""
    with a.at(dx=26, dy=22, rot=-8):
        a.rrect(-150, -92, 150, 102, 12, fill=SKY)
        a.poly([(-150, -92), (0, 36), (150, -92)], fill=PAPER)
        a.line([(-142, 94), (-52, 10)], w=5.5)
        a.line([(142, 94), (52, 10)], w=5.5)
        a.poly(scallop(0, 36, 40, 9, 5), fill=ac)
        a.text((0, 36), "42", 36, color=PAPER)


def e_note(a, ac):
    """Записка с вопросом: причина отказа."""
    with a.at(rot=6):
        a.poly([(-132, -128), (132, -128), (132, 74), (74, 132), (-132, 132)], fill=MUSTARD)
        a.poly([(132, 74), (74, 74), (74, 132)], fill=PAPER, w=5.5)
        for y, x1 in ((-82, 88), (-40, 56), (2, 70)):
            a.line([(-96, y), (x1, y)], w=9)
        a.text((4, 82), "?", 118, color=ac)
        a.ellipse(0, -148, 17, fill=ac, w=5.5)


EMBLEMS = {
    "menu": e_booth, "rules": e_rules, "mine": e_letters, "media": e_picture,
    "artist": e_palette, "artist_new": e_palette_new, "chars": e_heroes, "chars_new": e_hero_new,
    "caption": e_bubble, "credit": e_autograph, "edit": e_pencil, "sent": e_sent,
    "approved": e_seal, "rejected": e_reject, "reason": e_note,
}

# имя: (цвет поля, акцент, заголовок, подпись)
SPECS = {
    "menu": (VERMILION, VERMILION, "Предложка", "арты и творчество про 42 братух"),
    "rules": (TEAL, TEAL, "Правила", "коротко и по делу"),
    "mine": (PLUM, TEAL, "Мои заявки", "что с ними сейчас"),
    "media": (MUSTARD, VERMILION, "Работа", "пришли арт, видео или текст"),
    "artist": (MUSTARD, TEAL, "Художник", "кто это нарисовал"),
    "artist_new": (TEAL, VERMILION, "Новый художник", "занесём в список"),
    "chars": (MUSTARD, VERMILION, "Герои", "кто попал в кадр"),
    "chars_new": (TEAL, VERMILION, "Новый герой", "занесём в список"),
    "caption": (MUSTARD, TEAL, "Подпись", "пара слов к работе"),
    "credit": (MUSTARD, VERMILION, "Автограф", "подписать тебя в посте?"),
    "edit": (PLUM, VERMILION, "Правка", "что поменяем"),
    "sent": (TEAL, VERMILION, "Отправлено", "ждёт проверки админа"),
    "approved": (TEAL, TEAL, "Принято", "админ одобрил заявку"),
    "rejected": (VERMILION, VERMILION, "Отклонено", "причина — в подписи"),
    "reason": (VERMILION, VERMILION, "Причина", "что написать отправителю"),
}


# --- текстуры, марка, надписи ------------------------------------------------------------


def textured(rng, color, fine, blot):
    h, w = H * SS, W * SS
    low = rng.normal(0, 1, (h // 28, w // 28)).astype(np.float32)
    low = np.asarray(Image.fromarray(low, "F").resize((w, h), Image.BICUBIC))[..., None]
    arr = np.array(color, np.float32) + rng.normal(0, fine, (h, w, 1)) + low * blot
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB")


def stamp_mask():
    m = Image.new("L", (W * SS, H * SS), 0)
    d = ImageDraw.Draw(m)
    x0, y0, x1, y1 = STAMP
    d.rectangle((px(x0), px(y0), px(x1), px(y1)), fill=255)
    r, nx, ny = 11.5, 34, 16
    for i in range(nx):
        x = x0 + (x1 - x0) * (i + 0.5) / nx
        for y in (y0, y1):
            d.ellipse((px(x - r), px(y - r), px(x + r), px(y + r)), fill=0)
    for i in range(ny):
        y = y0 + (y1 - y0) * (i + 0.5) / ny
        for x in (x0, x1):
            d.ellipse((px(x - r), px(y - r), px(x + r), px(y + r)), fill=0)
    return m


def stroke_path(img, pts, w, color, closed=True):
    d = ImageDraw.Draw(img)
    P = [(px(x), px(y)) for x, y in pts]
    d.line(P + [P[0]] if closed else P, fill=color, width=px(w))
    for x, y in P:
        d.ellipse((x - px(w) / 2, y - px(w) / 2, x + px(w) / 2, y + px(w) / 2), fill=color)


def frame_pts(x0, y0, x1, y1, r):
    """Рамка с вогнутыми уголками, как у билета."""
    return arc(x1, y0, r, r, 180, 90) + arc(x1, y1, r, r, 270, 180) + arc(x0, y1, r, r, 360, 270) + arc(x0, y0, r, r, 90, 0)


def text_w(s, size, spacing=0.0):
    return font(size).getlength(s) / SS + spacing * (len(s) - 1)


def draw_text(img, xy, s, size, color, spacing=0.0, anchor="l"):
    """Надпись с межбуквенным интервалом; xy — левый край (или правый при anchor='r') и базовая линия."""
    d = ImageDraw.Draw(img)
    f = font(size)
    x, y = xy
    if anchor == "r":
        x -= text_w(s, size, spacing)
    for ch in s:
        d.text((px(x), px(y)), ch, font=f, fill=color, anchor="ls")
        x += f.getlength(ch) / SS + spacing


def fit_title(s, max_w):
    """Заголовок крупно в одну строку, а если не помещается — в две."""
    for size in range(188, 99, -4):
        if text_w(s, size) <= max_w:
            return [s], size
    words = s.split()
    if len(words) > 1:
        for size in range(124, 59, -4):
            if max(text_w(w, size) for w in words) <= max_w:
                return words, size
    size = 99
    while text_w(s, size) > max_w and size > 40:
        size -= 2
    return [s], size


def ring_text(img, cx, cy, r, s, size, mid_deg, top, color, spacing=2.0):
    """Надпись по дуге окружности: top — вдоль верхней дуги, иначе вдоль нижней."""
    f = font(size)
    widths = [f.getlength(ch) / SS + spacing for ch in s]
    total = sum(widths)
    ang = total / r  # радианы
    cur = -ang / 2
    for ch, wd in zip(s, widths):
        a = cur + wd / r / 2
        cur += wd / r
        tile = Image.new("RGBA", (px(size * 2), px(size * 2)), (0, 0, 0, 0))
        ImageDraw.Draw(tile).text((tile.width / 2, tile.height / 2), ch, font=f, fill=color, anchor="mm")
        if top:
            deg = mid_deg + math.degrees(a)
            x, y = cx + r * math.sin(math.radians(deg)), cy - r * math.cos(math.radians(deg))
            tile = tile.rotate(-deg, resample=Image.BICUBIC)
        else:
            deg = mid_deg + math.degrees(a)
            x, y = cx + r * math.sin(math.radians(deg)), cy + r * math.cos(math.radians(deg))
            tile = tile.rotate(deg, resample=Image.BICUBIC)
        img.alpha_composite(tile, (int(px(x) - tile.width / 2), int(px(y) - tile.height / 2)))


def uneven_ink(pm, rng):
    """Чернила ложатся неровно: пятнистая прозрачность оттиска."""
    a = np.asarray(pm.getchannel("A"), np.float32) / 255
    speck = rng.random(a.shape) > 0.07
    low = np.asarray(Image.fromarray(rng.random((H * SS // 20, W * SS // 20)).astype(np.float32), "F")
                     .resize((W * SS, H * SS), Image.BICUBIC))
    pm.putalpha(Image.fromarray((a * speck * (0.62 + 0.3 * low) * 255).astype(np.uint8)))
    return pm


def cancel_waves(rng, cx, cy, r, rot):
    """Волнистые линии погашения слева от штемпеля."""
    pm = layer()
    for dy in (-33, -11, 11, 33):
        stroke_path(pm, wave(cx - r - 215, cx - r + 8, cy + dy, 6, 52), 5.5, INK + (255,), closed=False)
    return uneven_ink(pm.rotate(rot, center=(px(cx), px(cy)), resample=Image.BICUBIC), rng)


def postmark(rng, cx, cy, r, rot):
    """Круглый штемпель."""
    pm = layer()
    stroke_path(pm, ellipse_pts(cx, cy, r, r), 5.5, INK + (255,))
    stroke_path(pm, ellipse_pts(cx, cy, r - 38, r - 38), 3.2, INK + (255,))
    ring_text(pm, cx, cy, r - 19, "ПРЕДЛОЖКА", 25, 0, True, INK + (255,), 3.0)
    ring_text(pm, cx, cy, r - 19, "42 CONFESSION", 22, 0, False, INK + (255,), 2.0)
    stroke_path(pm, star(cx, cy, 25, 11, 8), 3.2, INK + (255,))
    return uneven_ink(pm.rotate(rot, center=(px(cx), px(cy)), resample=Image.BICUBIC), rng)


def rosette(cx, cy, color):
    """Гильоше за эмблемой — гравированный узор, как на банкнотах."""
    g = layer()
    for i in range(17):
        r0 = 64 + i * 11
        pts = [(cx + (r0 + 5 * math.sin(18 * t)) * math.cos(t), cy + (r0 + 5 * math.sin(18 * t)) * math.sin(t) * 0.9)
               for t in np.linspace(0, 2 * math.pi, 420, endpoint=False)]
        stroke_path(g, pts, 1.7, color + (255,))
    x0, y0, x1, y1 = STAMP
    inner = Image.new("L", g.size, 0)
    ImageDraw.Draw(inner).polygon([(px(x), px(y)) for x, y in frame_pts(x0 + 46, y0 + 46, x1 - 46, y1 - 46, 9)], fill=255)
    g.putalpha(ImageChops.multiply(g.getchannel("A").point(lambda v: int(v * 0.2)), inner))
    return g


def render(name):
    field, accent, title, sub = SPECS[name]
    rng = np.random.default_rng(zlib.crc32(name.encode()))
    img = textured(rng, field, 6.0, 3.5).convert("RGBA")

    mask = stamp_mask()
    shade = ImageChops.offset(mask.filter(ImageFilter.GaussianBlur(px(7))).point(lambda v: int(v * 0.45)), px(4), px(9))
    dark = Image.new("RGBA", img.size, tuple(int(c * 0.4) for c in field) + (255,))
    dark.putalpha(shade)
    img = Image.alpha_composite(img, dark)
    paper = textured(rng, PAPER, 5.0, 4.0).convert("RGBA")
    img.paste(paper, (0, 0), mask)

    x0, y0, x1, y1 = STAMP
    stroke_path(img, frame_pts(x0 + 30, y0 + 30, x1 - 30, y1 - 30, 18), 4.2, INK)
    stroke_path(img, frame_pts(x0 + 42, y0 + 42, x1 - 42, y1 - 42, 11), 1.8, INK)

    ex, ey = 928, 350  # центр эмблемы
    img.alpha_composite(rosette(ex, ey, accent))

    # надписи слева
    left, right = 104, 700
    draw_text(img, (left, 128), "42 CONFESSION", 27, INK, spacing=5.0)
    lines, size = fit_title(title, right - left)
    base = 428
    for i, ln in enumerate(lines):
        draw_text(img, (left, base - (len(lines) - 1 - i) * size * 1.02), ln, size, INK)
    stroke_path(img, [(left + 4, base + 38), (left + 96, base + 38)], 9, accent, closed=False)
    draw_text(img, (left, base + 108), sub, 38, INK)

    # номинал
    draw_text(img, (1186, 188), "42", 124, accent, anchor="r")

    # линии погашения лежат под эмблемой, круглый штемпель — поверх
    img.alpha_composite(cancel_waves(rng, 1112, 508, 98, -13))
    art = Art(ex, ey, 0.98)
    EMBLEMS[name](art, accent)
    img.alpha_composite(ImageChops.offset(art.fill, px(MISS[0]), px(MISS[1])))
    img.alpha_composite(art.ink)
    img.alpha_composite(postmark(rng, 1112, 508, 98, -13))

    out = img.convert("RGB").resize((W, H), Image.LANCZOS)
    grain = rng.normal(0, 2.0, (H, W, 1))
    out = Image.fromarray(np.clip(np.asarray(out, np.float32) + grain, 0, 255).astype(np.uint8))
    OUT.mkdir(exist_ok=True)
    out.save(OUT / f"{name}.jpg", quality=92, subsampling=0, optimize=True)


if __name__ == "__main__":
    for n in sys.argv[1:] or SPECS:
        render(n)
        print("ok", n)
