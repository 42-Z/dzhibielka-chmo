# /// script
# requires-python = ">=3.10"
# dependencies = ["psycopg[binary]>=3.2"]
# ///
"""Сквозная проверка бота на поддельном Bot API и настоящем Postgres.

Поднимает локальный сервер, который отвечает как Telegram, запускает настоящий
бинарник бота и проводит через него сценарии: пользователь шлёт сообщения и жмёт
кнопки, тест сверяет вызовы Bot API и состояние БД.

    uv run --script tests/e2e.py build/tgbot [имя_сценария ...]

Postgres берётся из TEST_DATABASE_URL, иначе поднимается временный в Docker.
Между сценариями схема БД пересоздаётся.
"""
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import traceback
from email.parser import BytesParser
from email.policy import HTTP
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import cast

import psycopg

TOKEN = "123456:TEST"
CHANNEL = -1001234567890
ADMIN1, ADMIN2 = 1001, 1002
USER, USER2 = 2001, 2002
SCHEMA = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "sql", "schema.sql")

PEOPLE = {
    ADMIN1: ("Админ", "admin_one"),
    ADMIN2: ("Админ2", "admin_two"),
    USER: ("Вася", "vasya"),
    USER2: ("Петя", ""),
}


# --- поддельный Bot API ---------------------------------------------------------

class World:
    """Состояние поддельного Telegram: очередь update, журнал вызовов, сообщения."""

    def __init__(self):
        self.lock = threading.Condition()
        self.reset()

    def reset(self):
        with self.lock:
            self.updates = []
            self.next_update = 1000
            self.calls = []          # (метод, тело) каждого вызова, кроме getUpdates
            self.polls = []          # offset каждого getUpdates
            self.messages = {}       # (chat, id) -> {"text", "markup", "deleted", "method"}
            self.next_mid = 100
            self.fail = {}           # метод или "метод:chat" -> описание ошибки
            self.cb_answers = []
            self.uploads = []        # файлы, загруженные формой multipart: {"method", "name", "data"}
            self.bad_files = set()   # file_id, которые Telegram «забыл»

    # очередь и ожидание
    def enqueue(self, kind, payload):
        with self.lock:
            self.next_update += 1
            self.updates.append({"update_id": self.next_update, kind: payload})
            return self.next_update

    def settle(self, timeout=15):
        """Ждёт, пока бот обработает всё из очереди (подтвердит offset)."""
        deadline = time.monotonic() + timeout
        with self.lock:
            target = self.next_update + 1
            while not (self.polls and self.polls[-1] >= target):
                left = deadline - time.monotonic()
                if left <= 0:
                    raise AssertionError("бот не обработал update за %s с" % timeout)
                self.lock.wait(min(left, 0.2))

    def chat_of(self, body):
        return str(body.get("chat_id"))

    @staticmethod
    def banner_of(file_id):
        """Имя баннера по file_id, который выдал поддельный Telegram («BNR:menu.jpg:3»), или None."""
        if isinstance(file_id, str) and file_id.startswith("BNR:"):
            return file_id.split(":")[1].removesuffix(".jpg")
        return None

    def new_message(self, body, method, text=None):
        self.next_mid += 1
        mid = self.next_mid
        self.messages[(self.chat_of(body), mid)] = {
            "id": mid,
            "chat": self.chat_of(body),
            "method": method,
            "text": text if text is not None else body.get("text", body.get("caption", "")),
            "markup": body.get("reply_markup"),
            "body": body,
            "banner": self.banner_of(body.get("photo")),
            "deleted": False,
        }
        return mid

    def photo_result(self, mid, file_id):
        return {"message_id": mid, "photo": [{"file_id": file_id + "_s", "width": 90, "height": 45},
                                              {"file_id": file_id, "width": 1280, "height": 640}]}

    def take_upload(self, method, body, field):
        """Картинка из multipart-формы: запоминает файл и выдаёт новый file_id."""
        name, data = body["_files"][field]
        self.uploads.append({"method": method, "name": name, "data": data})
        return "BNR:%s:%d" % (name, len(self.uploads))

    def edit_target(self, body, want_photo):
        """Сообщение для правки либо описание ошибки Telegram."""
        m = self.messages.get((self.chat_of(body), body["message_id"]))
        if not m or m["deleted"]:
            return None, "Bad Request: message to edit not found"
        is_photo = m["method"] == "sendPhoto"
        if want_photo and not is_photo:
            return None, "Bad Request: there is no caption in the message to edit"
        if not want_photo and is_photo:
            return None, "Bad Request: there is no text in the message to edit"
        return m, None

    def handle(self, method, body):
        """Возвращает (http_status, json)."""
        if method == "getUpdates":
            offset = body.get("offset", 0)
            with self.lock:
                self.polls.append(offset)
                self.lock.notify_all()
                # подтверждённые offset-ом update Telegram больше не отдаёт
                self.updates = [u for u in self.updates if u["update_id"] >= offset]
                pending = list(self.updates)
            if not pending:
                time.sleep(0.15)
            return 200, {"ok": True, "result": pending}
        with self.lock:
            self.calls.append((method, body))
            chat = self.chat_of(body)
            key = "%s:%s" % (method, chat)
            err = self.fail.get(key) or self.fail.get(method)
            if err:
                return 400, {"ok": False, "error_code": 400, "description": err}
            if method == "sendMessage":
                return 200, {"ok": True, "result": {"message_id": self.new_message(body, method)}}
            if method == "sendPhoto":
                if "_files" in body:
                    body["photo"] = self.take_upload(method, body, "photo")
                elif body.get("photo") in self.bad_files:
                    return 400, {"ok": False, "error_code": 400,
                                 "description": "Bad Request: wrong file identifier/HTTP URL specified"}
                if len(body.get("caption", "")) > 1024:
                    return 400, {"ok": False, "error_code": 400, "description": "Bad Request: message caption is too long"}
                body["_banner"] = self.banner_of(body.get("photo")) is not None
                mid = self.new_message(body, method)
                return 200, {"ok": True, "result": self.photo_result(mid, body["photo"])}
            if method in ("sendVideo", "sendAnimation", "sendDocument"):
                return 200, {"ok": True, "result": {"message_id": self.new_message(body, method)}}
            if method == "sendMediaGroup":
                result = []
                for item in body["media"]:
                    b = {"chat_id": body["chat_id"], "caption": item.get("caption", "")}
                    mid = self.new_message(b, method)
                    result.append({"message_id": mid})
                return 200, {"ok": True, "result": result}
            if method == "editMessageText":
                m, err = self.edit_target(body, False)
                if err:
                    return 400, {"ok": False, "error_code": 400, "description": err}
                if m["text"] == body["text"] and m["markup"] == body.get("reply_markup"):
                    return 400, {"ok": False, "error_code": 400,
                                 "description": "Bad Request: message is not modified"}
                m["text"], m["markup"] = body["text"], body.get("reply_markup")
                return 200, {"ok": True, "result": {"message_id": body["message_id"]}}
            if method in ("editMessageCaption", "editMessageMedia"):
                m, err = self.edit_target(body, True)
                if err:
                    return 400, {"ok": False, "error_code": 400, "description": err}
                if method == "editMessageCaption":
                    caption, photo = body["caption"], m["body"]["photo"]
                else:
                    media = body["media"]
                    caption, photo = media.get("caption", ""), media["media"]
                    if photo.startswith("attach://"):
                        photo = self.take_upload(method, body, photo[len("attach://"):])
                    elif photo in self.bad_files:
                        return 400, {"ok": False, "error_code": 400,
                                     "description": "Bad Request: wrong file identifier/HTTP URL specified"}
                if len(caption) > 1024:
                    return 400, {"ok": False, "error_code": 400, "description": "Bad Request: message caption is too long"}
                if (m["text"], m["markup"], m["body"]["photo"]) == (caption, body.get("reply_markup"), photo):
                    return 400, {"ok": False, "error_code": 400,
                                 "description": "Bad Request: message is not modified"}
                m["text"], m["markup"], m["body"]["photo"] = caption, body.get("reply_markup"), photo
                m["banner"] = self.banner_of(photo)
                return 200, {"ok": True, "result": self.photo_result(m["id"], photo)}
            if method == "deleteMessage":
                m = self.messages.get((chat, body["message_id"]))
                if not m or m["deleted"]:
                    return 400, {"ok": False, "error_code": 400,
                                 "description": "Bad Request: message to delete not found"}
                m["deleted"] = True
                return 200, {"ok": True, "result": True}
            if method == "answerCallbackQuery":
                self.cb_answers.append(body)
                return 200, {"ok": True, "result": True}
            if method == "answerInlineQuery":
                return 200, {"ok": True, "result": True}
            if method == "getChat":
                return 200, {"ok": True, "result": {"id": body["chat_id"], "type": "private"}}
        return 404, {"ok": False, "error_code": 404, "description": "Not Found"}


WORLD = World()


class FakeBotApi(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):
        pass

    def respond(self, status, payload):
        data = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # бота остановили во время long polling

    def do_POST(self):
        raw = self.rfile.read(int(self.headers["Content-Length"]))
        prefix = "/bot%s/" % TOKEN
        if not self.path.startswith(prefix):
            return self.respond(401, {"ok": False, "error_code": 401, "description": "Unauthorized"})
        ctype = self.headers.get("Content-Type", "")
        if ctype == "application/json":
            body = json.loads(raw)
        elif ctype.startswith("multipart/form-data"):
            body = self.parse_form(ctype, raw)
        else:
            return self.respond(400, {"ok": False, "error_code": 400, "description": "нужен JSON или multipart"})
        status, payload = WORLD.handle(self.path[len(prefix):], body)
        self.respond(status, payload)

    @staticmethod
    def parse_form(ctype, raw):
        """multipart/form-data -> тело запроса как у JSON; файлы лежат в body["_files"][поле] = (имя, байты)."""
        msg = BytesParser(policy=HTTP).parsebytes(b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + raw)
        body, files = {}, {}
        for part in msg.iter_parts():
            name = part.get_param("name", header="content-disposition")
            data = cast(bytes, part.get_payload(decode=True))
            if part.get_filename() is not None:
                files[name] = (part.get_filename(), data)
            elif name in ("chat_id", "message_id"):
                body[name] = int(data)
            elif name in ("reply_markup", "media"):
                body[name] = json.loads(data)
            else:
                body[name] = data.decode()
        body["_files"] = files
        return body


# --- процесс бота и БД ----------------------------------------------------------

class Bot:
    def __init__(self, binary, env):
        full = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}
        for k in ("BOT_TOKEN", "DATABASE_URL", "ADMIN_IDS", "CHANNEL_ID"):
            full.pop(k, None)
        full.update(env)
        self.proc = subprocess.Popen([binary], env=full, stderr=subprocess.PIPE, text=True,
                                     cwd=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
        self.log = []
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        assert self.proc.stderr is not None
        for line in self.proc.stderr:
            self.log.append(line.rstrip("\n"))

    def wait_log(self, needle, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if any(needle in line for line in self.log):
                return True
            time.sleep(0.05)
        return False

    def stop(self):
        if self.proc.poll() is None:
            self.proc.send_signal(signal.SIGTERM)
        try:
            code = self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            code = self.proc.wait()
        self.reader.join(timeout=1)
        return code


class Postgres:
    """Временный Postgres в Docker либо внешний из TEST_DATABASE_URL."""

    def __init__(self):
        self.container = None
        self.url = os.environ.get("TEST_DATABASE_URL")
        if self.url:
            return
        out = subprocess.run(
            ["docker", "run", "--rm", "-d", "-e", "POSTGRES_PASSWORD=test", "-e", "POSTGRES_DB=bot",
             "-p", "127.0.0.1::5432", "postgres:17-alpine"],
            capture_output=True, text=True, check=True)
        self.container = out.stdout.strip()
        port = subprocess.run(["docker", "port", self.container, "5432/tcp"],
                              capture_output=True, text=True, check=True).stdout.split(":")[-1].strip()
        self.url = "postgresql://postgres:test@127.0.0.1:%s/bot" % port
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                psycopg.connect(self.url, connect_timeout=2).close()
                return
            except psycopg.OperationalError:
                time.sleep(0.5)
        raise RuntimeError("Postgres не поднялся")

    def reset(self):
        with psycopg.connect(self.url, autocommit=True) as c:
            c.execute("DROP SCHEMA public CASCADE")
            c.execute("CREATE SCHEMA public")

    def query(self, sql, *args):
        with psycopg.connect(self.url, autocommit=True) as c:
            return c.execute(sql, args).fetchall()

    def close(self):
        if self.container:
            subprocess.run(["docker", "stop", self.container], capture_output=True)


# --- помощники сценариев --------------------------------------------------------

class Ctx:
    """Всё, что нужно сценарию: мир, бот, БД и действия пользователей."""

    def __init__(self, binary, pg):
        self.binary, self.pg = binary, pg
        self.api_url = None
        self.bot = None

    def start(self, **env_over):
        env = {
            "BOT_TOKEN": TOKEN,
            "TELEGRAM_API_URL": self.api_url,
            "DATABASE_URL": self.pg.url,
            "ADMIN_IDS": "%d,%d" % (ADMIN1, ADMIN2),
            "CHANNEL_ID": str(CHANNEL),
        }
        env.update(env_over)
        env = {k: v for k, v in env.items() if v is not None}
        self.bot = Bot(self.binary, env)
        if not env_over:
            check(self.bot.wait_log("Бот запущен", 10), "бот не запустился: %s" % self.bot.log)
        return self.bot

    def restart(self):
        assert self.bot is not None
        self.bot.stop()
        self.start()

    # --- отправка update от пользователя
    def frm(self, uid):
        name, username = PEOPLE[uid]
        d = {"id": uid, "is_bot": False, "first_name": name}
        if username:
            d["username"] = username
        return d

    def say(self, uid, text=None, settle=True, **extra):
        mid = WORLD.next_mid + 1000 + WORLD.next_update
        msg = {"message_id": mid, "from": self.frm(uid), "chat": {"id": uid, "type": "private"}, "date": 0}
        if text is not None:
            msg["text"] = text
        msg.update(extra)
        # Сообщение пользователя существует в чате: бот вправе его удалить.
        with WORLD.lock:
            WORLD.messages[(str(uid), mid)] = {"id": mid, "chat": str(uid), "method": "user",
                                               "text": text or "", "markup": None, "deleted": False}
        WORLD.enqueue("message", msg)
        if settle:
            WORLD.settle()

    def photo(self, uid, file_id="PH1", **extra):
        self.say(uid, photo=[{"file_id": file_id + "_s", "width": 90, "height": 90},
                              {"file_id": file_id, "width": 800, "height": 800}], **extra)

    def press(self, uid, text, panel=None):
        """Нажимает кнопку, в тексте которой есть text, на последней панели бота в чате."""
        m = panel or self.last_panel(uid)
        assert m, "в чате %s нет сообщения бота" % uid
        for row in (m["markup"] or {}).get("inline_keyboard", []):
            for b in row:
                if text in b["text"]:
                    return self.press_data(uid, b["callback_data"], m)
        raise AssertionError("нет кнопки %r в %r; есть: %s" % (text, m["text"][:60], self.buttons(m)))

    def press_data(self, uid, data, m=None, settle=True):
        m = m or self.last_panel(uid)
        WORLD.enqueue("callback_query", {
            "id": "cb%d" % (WORLD.next_update + 1), "from": self.frm(uid), "data": data,
            "message": {"message_id": m["id"], "chat": {"id": uid, "type": "private"}}})
        if settle:
            WORLD.settle()

    def inline(self, uid, query="", offset="", settle=True):
        qid = "iq%d" % (WORLD.next_update + 1)
        WORLD.enqueue("inline_query", {"id": qid, "from": self.frm(uid), "query": query,
                                       "offset": offset, "chat_type": "private"})
        if settle:
            WORLD.settle()
        return self.inline_answer(qid)

    def inline_answer(self, qid):
        for method, body in reversed(WORLD.calls):
            if method == "answerInlineQuery" and body["inline_query_id"] == qid:
                return body
        raise AssertionError("нет ответа на inline-запрос")

    def pick(self, uid, text):
        """Пользователь выбрал пункт выпадающего списка: бот получает сообщение via_bot."""
        self.say(uid, text, via_bot={"id": 777, "is_bot": True, "first_name": "bot", "username": "bot"})

    # --- что видно в чатах
    def panels(self, uid):
        """Живые панели бота в чате: сообщения с кнопками, текстом или баннером. Пояснения
        без кнопок («так нельзя») панелью не считаются."""
        return [m for (c, _), m in sorted(WORLD.messages.items(), key=lambda kv: kv[0][1])
                if c == str(uid) and not m["deleted"] and m["markup"]
                and (m["method"] == "sendMessage" or m["banner"])]

    def last_panel(self, uid):
        msgs = self.panels(uid)
        return msgs[-1] if msgs else None

    def texts(self, uid):
        return [m["text"] for (c, _), m in sorted(WORLD.messages.items(), key=lambda kv: kv[0][1])
                if c == str(uid) and not m["deleted"] and m["method"] != "user"]

    @staticmethod
    def buttons(m):
        return [b["text"] for row in (m["markup"] or {}).get("inline_keyboard", []) for b in row]

    def sent(self, method, chat=None):
        """Вызовы метода, кроме баннеров бота (их смотрит banner_calls)."""
        return [b for (mt, b) in WORLD.calls if mt == method and not b.get("_banner")
                and (chat is None or str(b.get("chat_id")) == str(chat))]

    def banner_calls(self, method, chat=None):
        return [b for (mt, b) in WORLD.calls if mt == method and b.get("_banner")
                and (chat is None or str(b.get("chat_id")) == str(chat))]

    def channel_posts(self):
        return [(mt, b) for (mt, b) in WORLD.calls
                if str(b.get("chat_id")) == str(CHANNEL) and mt.startswith("send")]

    def seed(self, artists=(), characters=()):
        """Наполняет справочник напрямую в БД (в тестах это быстрее, чем через админа)."""
        with psycopg.connect(self.pg.url, autocommit=True) as c:
            for name, link in artists:
                c.execute("INSERT INTO artists (name, name_key, link) VALUES (%s, %s, %s)",
                          (name, name.lower(), link))
            for name, aliases in characters:
                tag = re.sub(r"[^\w]+", "_", name).strip("_")
                c.execute("INSERT INTO characters (name, name_key, aliases, search, tag) "
                          "VALUES (%s, %s, %s, %s, %s)",
                          (name, name.lower(), aliases, (name + " " + aliases).lower(), tag))


SCENARIOS = []


def scenario(fn):
    SCENARIOS.append(fn)
    return fn


def check(cond, what):
    if not cond:
        raise AssertionError(what)


# --- сценарии -------------------------------------------------------------------

@scenario
def start_menu(c):
    c.start()
    c.say(USER, "/start")
    m = c.last_panel(USER)
    check(m and "42 CONFESSION" in m["text"], "приветствие")
    check(any("Предложить работу" in t for t in c.buttons(m)), "кнопка «Предложить работу»")
    c.say(USER, "/id")
    check(any("2001" in t for t in c.texts(USER)), "/id показывает id")
    c.say(USER2, "привет")
    check("Что делаем" in c.last_panel(USER2)["text"], "на произвольный текст вне мастера бот показывает меню")


@scenario
def admin_backlog(c):
    # Второй админ ещё не писал боту: Telegram не даёт ему писать первым.
    for method in ("sendMessage", "sendPhoto", "getChat"):
        WORLD.fail["%s:%d" % (method, ADMIN2)] = "Forbidden: bot can't initiate conversation with a user"
    c.start()
    check(c.bot.wait_log("Админ %d ещё не писал боту" % ADMIN2, 5), "предупреждение при старте: %s" % c.bot.log)
    seed_basic(c)
    new_work(c)
    check(card_of(c, ADMIN1) and not any(m["chat"] == str(ADMIN2) for m in WORLD.messages.values()),
          "карточка дошла первому админу и не дошла второму")
    check(c.bot.wait_log("Заявка #1: карточка не дошла", 1) is False, "первому админу карточка дошла")
    WORLD.fail.clear()
    c.say(ADMIN2, "/start")
    check("Заявка #1" in card_of(c, ADMIN2)["text"], "после /start второй админ получил карточку")
    c.say(ADMIN2, "/start")
    check(len([m for m in WORLD.messages.values() if m["chat"] == str(ADMIN2) and "Заявка #" in m["text"]]) == 1,
          "карточка не дублируется")
    press_card(c, ADMIN2, "Опубликовать")
    check("✅ Опубликовано" in card_of(c, ADMIN1)["text"], "решение второго админа видно у первого")


@scenario
def admin_busy_and_race(c):
    c.start()
    seed_basic(c)
    new_work(c)
    # админ занят своей заявкой: чужие «Отклонить» и «Исправить» не затирают её
    c.say(ADMIN1, "/start")
    c.press(ADMIN1, "Предложить братуху")
    c.say(ADMIN1, "Черновик Админа")
    for text in ("Отклонить", "Исправить"):
        press_card(c, ADMIN1, text)
        check("Сначала закончи" in last_alert(c), "%s при незаконченной заявке: %r" % (text, last_alert(c)))
    check(c.pg.query("SELECT state FROM users WHERE id = %s", ADMIN1) == [("e_extra",)], "шаг админа не затёрт")
    c.say(ADMIN1, "/cancel")
    # гонка: A ждёт причину, B успел опубликовать
    press_card(c, ADMIN1, "Отклонить")
    stale_prompt = c.last_panel(ADMIN1)
    press_card(c, ADMIN2, "Опубликовать")
    c.press(ADMIN1, "Без причины", stale_prompt)
    check("решили" in last_alert(c), "причина к решённой заявке: %r" % last_alert(c))
    check(c.pg.query("SELECT state FROM users WHERE id = %s", ADMIN1) == [("",)], "ожидание причины сброшено")
    check(c.pg.query("SELECT status FROM requests") == [("approved",)], "решение второго админа сохранилось")


def seed_basic(c):
    c.seed(artists=[("Мария Рисунок", "https://t.me/maria"), ("Борис", "")],
           characters=[("Санька Штормовой", "sankashtorm"), ("Лёнька", "леня, лёнечка"), ("Валенка", "")])


def card_of(_c, admin):
    """Последняя карточка заявки в чате админа (сообщение с кнопками решения)."""
    for (chat, _), m in sorted(WORLD.messages.items(), key=lambda kv: kv[0][1], reverse=True):
        if chat == str(admin) and m["method"] == "sendMessage" and "Заявка #" in m["text"]:
            return m
    raise AssertionError("у админа %s нет карточки" % admin)


@scenario
def work_flow(c):
    c.start()
    seed_basic(c)
    c.say(USER, "/start")
    c.press(USER, "Предложить работу")
    check("Новая работа" in c.last_panel(USER)["text"], "экран загрузки работы")
    c.photo(USER, "PH1", caption="Подпись автора")
    check("Принято: <b>1</b>" in c.last_panel(USER)["text"], "принято одно фото")
    c.press(USER, "Дальше")
    check("Кто автор" in c.last_panel(USER)["text"], "экран художника")

    # выпадающий список художников: служебные пункты и поиск без учёта регистра
    ans = c.inline(USER, "")
    titles = [r["title"] for r in ans["results"]]
    check("Мария Рисунок" in titles and any("моя работа" in t for t in titles), "список художников: %s" % titles)
    ans = c.inline(USER, "МАРИ")
    titles = [r["title"] for r in ans["results"]]
    check(titles[-1] == "Мария Рисунок" and "Борис" not in titles, "поиск по подстроке: %s" % titles)
    c.pick(USER, "Мария Рисунок")
    check("Мария Рисунок" in c.last_panel(USER)["text"], "художник выбран")
    c.press(USER, "Дальше")

    # братухи: поиск по псевдониму, выбор, новый братуха
    ans = c.inline(USER, "ЛЁНЕЧ")
    check([r["title"] for r in ans["results"] if not r["id"].startswith("s")] == ["Лёнька"], "поиск по псевдониму")
    c.pick(USER, "Лёнька")
    check("Лёнька" in c.last_panel(USER)["text"], "братуха выбран")
    ans = c.inline(USER, "")
    check("Лёнька" not in [r["title"] for r in ans["results"]], "выбранный братуха скрыт из списка")
    c.press(USER, "Нет в списке")
    c.say(USER, "Новый Герой, Другой")
    check("Новый Герой" in c.last_panel(USER)["text"], "новые братухи в панели")
    c.press(USER, "Дальше")
    check("Подпись" in c.last_panel(USER)["text"], "экран подписи")
    c.press(USER, "Оставить")
    c.press(USER, "Указать меня")
    review = c.last_panel(USER)["text"]
    check("Так будет выглядеть пост" in review and "Подпись автора" in review, "предпросмотр")
    c.press(USER, "Отправить на проверку")
    check("Заявка отправлена" in c.last_panel(USER)["text"], "подтверждение отправителю")

    # карточка у обоих админов, содержимое видно
    for admin in (ADMIN1, ADMIN2):
        card = card_of(c, admin)
        check("Новый Герой" in card["text"] and "Опубликовать" in " ".join(c.buttons(card)), "карточка админа %d" % admin)
        check(any(b["photo"] == "PH1" for b in c.sent("sendPhoto", admin)), "предпросмотр фото у админа")

    # публикация
    c.press(ADMIN1, "Опубликовать")
    posts = c.channel_posts()
    check(len(posts) == 1 and posts[0][0] == "sendPhoto", "один пост в канале: %s" % posts)
    cap = posts[0][1]["caption"]
    for needle in ("Подпись автора", 'href="https://t.me/maria">Мария Рисунок</a>', "Лёнька", "Новый Герой",
                   "#42братухи", "#Лёнька", "#Новый_Герой", "#Другой", "@vasya"):
        check(needle in cap, "в подписи нет %r: %s" % (needle, cap))
    check(posts[0][1]["parse_mode"] == "HTML" and posts[0][1]["photo"] == "PH1", "параметры поста")
    check(any("опубликована" in t for t in c.texts(USER)), "отправителю пришло уведомление")
    rows = c.pg.query("SELECT status, decided_by FROM requests")
    check(rows == [("approved", ADMIN1)], "статус в БД: %s" % rows)
    check(c.pg.query("SELECT count(*) FROM characters")[0][0] == 5, "новые братухи внесены в справочник")
    for admin in (ADMIN1, ADMIN2):
        check("✅ Опубликовано" in card_of(c, admin)["text"], "карточка админа %d обновлена" % admin)


def press_card(c, admin, text):
    c.press(admin, text, card_of(c, admin))


def last_alert(_c):
    return WORLD.cb_answers[-1].get("text", "")


def new_work(c, uid=USER, photos=("PH1",), artist="Мария Рисунок", chars=(), caption=None, credit=False):
    """Быстрый путь: подготовить заявку на работу и отправить её на проверку."""
    c.say(uid, "/start")
    c.press(uid, "Предложить работу")
    for p in photos:
        c.photo(uid, p)
    c.press(uid, "Дальше")
    c.pick(uid, artist)
    c.press(uid, "Дальше")
    for ch in chars:
        c.pick(uid, ch)
    c.press(uid, "Дальше")
    if caption:
        c.say(uid, caption)
    else:
        c.press(uid, "Пропустить")
    c.press(uid, "Указать меня" if credit else "Остаться анонимом")
    c.press(uid, "Отправить на проверку")


@scenario
def startup_errors(c):
    base = {"BOT_TOKEN": TOKEN, "TELEGRAM_API_URL": c.api_url, "DATABASE_URL": c.pg.url,
            "ADMIN_IDS": "1001", "CHANNEL_ID": "@chan"}
    for name in ("BOT_TOKEN", "DATABASE_URL", "ADMIN_IDS", "CHANNEL_ID"):
        env = {k: v for k, v in base.items() if k != name}
        bot = Bot(c.binary, env)
        check(bot.proc.wait(timeout=10) == 1 and bot.wait_log(name, 2), "без %s выход с кодом 1" % name)
    bot = Bot(c.binary, dict(base, ADMIN_IDS="abc"))
    check(bot.proc.wait(timeout=10) == 1, "ADMIN_IDS без чисел — выход с кодом 1")
    bot = Bot(c.binary, dict(base, DATABASE_URL="postgresql://nobody:x@127.0.0.1:1/none"))
    check(bot.proc.wait(timeout=10) == 1 and bot.wait_log("БД", 2), "недоступная БД — выход с кодом 1")
    bot = Bot(c.binary, dict(base, BOT_TOKEN="bad-token"))
    check(bot.wait_log("Unauthorized", 10), "ошибка Unauthorized в логе")
    check(bot.proc.poll() is None, "бот не падает после ошибки токена")
    code = bot.stop()
    check(code == -signal.SIGTERM, "завершение по SIGTERM")


@scenario
def album_work(c):
    c.start()
    seed_basic(c)
    c.say(USER, "/start")
    c.press(USER, "Предложить работу")
    for fid in ("A", "B", "C"):
        c.photo(USER, fid, media_group_id="g1")
    check("Принято: <b>3</b>" in c.last_panel(USER)["text"], "альбом принят целиком")
    check(len(c.panels(USER)) == 1, "на альбом одна панель")
    c.press(USER, "Дальше")
    c.pick(USER, "Борис")
    c.press(USER, "Дальше")
    c.press(USER, "Дальше")
    c.press(USER, "Пропустить")
    c.press(USER, "Остаться анонимом")
    c.press(USER, "Отправить на проверку")
    check(len(c.sent("sendMediaGroup", ADMIN1)) == 1, "админ видит альбом")
    press_card(c, ADMIN1, "Опубликовать")
    groups = c.sent("sendMediaGroup", CHANNEL)
    check(len(groups) == 1, "альбом ушёл в канал одним сообщением")
    media = groups[0]["media"]
    check([m["media"] for m in media] == ["A", "B", "C"] and all(m["type"] == "photo" for m in media), "порядок и типы")
    check("Борис" in media[0]["caption"] and all("caption" not in m for m in media[1:]), "подпись только на первом")


@scenario
def text_work(c):
    c.start()
    seed_basic(c)
    c.say(USER, "/start")
    c.press(USER, "Предложить работу")
    c.say(USER, "Стих про <братуху> & друзей")
    check("Текст принят" in c.last_panel(USER)["text"], "текст принят")
    c.press(USER, "Дальше")
    c.pick(USER, "Борис")
    c.press(USER, "Дальше")
    c.press(USER, "Дальше")
    check("Подпись отправителя" in c.last_panel(USER)["text"] or "Подписать" in c.last_panel(USER)["text"],
          "у текстовой работы нет шага подписи")
    c.press(USER, "Остаться анонимом")
    c.press(USER, "Отправить на проверку")
    check(c.sent("sendMessage", ADMIN1) and not c.sent("sendPhoto", ADMIN1) and not c.sent("sendMediaGroup", ADMIN1),
          "текстовую работу не дублируют отдельным предпросмотром")
    press_card(c, ADMIN2, "Исправить")
    check("Подпись" not in " ".join(b for b in c.buttons(c.last_panel(ADMIN2)) if "отправителя" not in b),
          "у текстовой работы нет кнопки подписи")
    c.press(ADMIN2, "Готово")
    press_card(c, ADMIN2, "Опубликовать")
    posts = c.channel_posts()
    check(len(posts) == 1 and posts[0][0] == "sendMessage", "текст ушёл сообщением")
    text = posts[0][1]["text"]
    check("Стих про &lt;братуху&gt; &amp; друзей" in text and "Борис" in text, "текст экранирован: %s" % text)


@scenario
def reject_flow(c):
    c.start()
    seed_basic(c)
    new_work(c)
    press_card(c, ADMIN1, "Отклонить")
    check("причину" in c.last_panel(ADMIN1)["text"], "админ видит запрос причины")
    c.say(ADMIN1, "Не по теме канала")
    check(any("отклонена" in t and "Не по теме канала" in t for t in c.texts(USER)), "отправитель получил причину")
    check("❌ Отклонено" in card_of(c, ADMIN2)["text"], "карточка второго админа обновлена")
    check(c.channel_posts() == [], "в канал ничего не ушло")
    check(c.pg.query("SELECT status, reason FROM requests") == [("rejected", "Не по теме канала")], "статус в БД")
    new_work(c)
    press_card(c, ADMIN2, "Отклонить")
    c.press(ADMIN2, "Без причины")
    check(c.pg.query("SELECT status, reason FROM requests ORDER BY id") ==
          [("rejected", "Не по теме канала"), ("rejected", "")], "отказ без причины")
    c.say(USER, "/start")
    c.press(USER, "Мои заявки")
    mine = c.last_panel(USER)["text"]
    check("#1" in mine and "Не по теме канала" in mine and "#2" in mine, "«Мои заявки»: %s" % mine)


@scenario
def admin_fix(c):
    c.start()
    seed_basic(c)
    new_work(c, caption="старая подпись", chars=("Лёнька",))
    press_card(c, ADMIN1, "Исправить")
    check("Исправление заявки #1" in c.last_panel(ADMIN1)["text"], "меню правки")
    c.press(ADMIN1, "Подпись")
    c.say(ADMIN1, "новая подпись")
    check("Исправление заявки #1" in c.last_panel(ADMIN1)["text"] and "новая подпись" in c.last_panel(ADMIN1)["text"],
          "после шага возврат в меню правки")
    c.press(ADMIN1, "Художник")
    c.pick(ADMIN1, "Борис")
    c.press(ADMIN1, "Готово")
    c.press(ADMIN1, "Братухи")
    c.press(ADMIN1, "Лёнька")  # убрать выбранного братуху
    c.press(ADMIN1, "Готово")
    c.press(ADMIN1, "Подпись отправителя")
    c.press(ADMIN1, "Готово")
    check("новая подпись" in card_of(c, ADMIN2)["text"] and "Борис" in card_of(c, ADMIN2)["text"],
          "карточка второго админа обновлена после правки")
    press_card(c, ADMIN2, "Опубликовать")
    cap = c.channel_posts()[0][1]["caption"]
    check("новая подпись" in cap and "Борис" in cap and "Лёнька" not in cap and "старая" not in cap, "правки в посте: %s" % cap)
    check("@vasya" in cap, "подпись отправителя включена правкой админа")


@scenario
def decisions_are_final(c):
    c.start()
    seed_basic(c)
    new_work(c)
    stale = card_of(c, ADMIN2)
    data = stale["markup"]["inline_keyboard"][0][0]["callback_data"]
    press_card(c, ADMIN1, "Опубликовать")
    c.press_data(ADMIN2, data, stale)  # кнопку могли нажать до того, как карточка обновилась
    check("решили" in last_alert(c), "повторное решение отклонено: %r" % last_alert(c))
    check(len(c.channel_posts()) == 1, "пост один")
    c.press_data(USER, "a:ok:1", card_of(c, ADMIN1))
    check("для админов" in last_alert(c), "обычный пользователь не может решать")
    new_work(c)
    c.press_data(USER, "a:ok:2", card_of(c, ADMIN1))
    check(len(c.channel_posts()) == 1 and c.pg.query("SELECT status FROM requests WHERE id = 2") == [("pending",)],
          "чужая кнопка не публикует")


@scenario
def publish_failure(c):
    c.start()
    seed_basic(c)
    c.say(USER, "/start")
    c.press(USER, "Предложить работу")
    c.photo(USER, "PH9")
    c.press(USER, "Дальше")
    c.pick(USER, "➕ Нет в списке")
    c.say(USER, "Новичок")
    c.say(USER, "vk.com/novichok")
    c.press(USER, "Нет в списке")
    c.say(USER, "Совсем Новый")
    c.press(USER, "Дальше")
    c.press(USER, "Пропустить")
    c.press(USER, "Остаться анонимом")
    c.press(USER, "Отправить на проверку")
    # Ошибки Telegram админ видит по-русски и окном, а не голым «Bad Request».
    causes = [
        ("Bad Request: chat not found", "Бота нет в канале"),
        ("Forbidden: bot is not a member of the channel chat", "Бота нет в канале"),
        ("Forbidden: bot was kicked from the channel chat", "Бота нет в канале"),
        ("Bad Request: not enough rights to send photos to the chat", "нет права публиковать"),
        ("Bad Request: wrong file identifier", "Не получилось опубликовать: Bad Request: wrong file identifier"),
    ]
    for desc, expected in causes:
        WORLD.fail["sendPhoto:%d" % CHANNEL] = desc
        press_card(c, ADMIN1, "Опубликовать")
        alert = last_alert(c)
        check(expected in alert, "%s → %r" % (desc, alert))
        check(WORLD.cb_answers[-1].get("show_alert") is True, "причина показана окном")
        check(len(alert) <= 200, "текст помещается в окно Telegram: %d" % len(alert))
    attempts = len(c.channel_posts())
    check(c.pg.query("SELECT status FROM requests") == [("pending",)], "заявка осталась в ожидании")
    check(c.pg.query("SELECT count(*) FROM artists WHERE name = 'Новичок'")[0][0] == 0 and
          c.pg.query("SELECT count(*) FROM characters WHERE name = 'Совсем Новый'")[0][0] == 0,
          "новые записи откатились")
    del WORLD.fail["sendPhoto:%d" % CHANNEL]
    press_card(c, ADMIN1, "Опубликовать")
    check(len(c.channel_posts()) == attempts + 1, "после починки пост вышел")
    check(c.pg.query("SELECT name, link FROM artists WHERE name = 'Новичок'") == [("Новичок", "https://vk.com/novichok")],
          "художник внесён со ссылкой")
    check(c.pg.query("SELECT count(*) FROM request_chars")[0][0] == 1, "новый братуха привязан к заявке")
    cap = c.channel_posts()[0][1]["caption"]
    check('href="https://vk.com/novichok">Новичок</a>' in cap and "#Совсем_Новый" in cap, "в посте новые данные: %s" % cap)


@scenario
def entity_requests(c):
    c.start()
    seed_basic(c)
    # художник от обычного пользователя
    c.say(USER, "/start")
    c.press(USER, "Предложить художника")
    c.say(USER, "борис")
    check("уже есть" in c.texts(USER)[-1], "дубль имени отклонён сразу")
    c.say(USER, "Новая Художница")
    c.say(USER, "не ссылка")
    check("Не похоже на ссылку" in c.texts(USER)[-1], "плохая ссылка")
    c.say(USER, "https://example.com/" + "a" * 300)
    check("Не похоже на ссылку" in c.texts(USER)[-1], "слишком длинная ссылка")
    c.say(USER, "@art_girl")
    c.say(USER, "рисует в стиле комиксов")
    check("Новая Художница" in c.last_panel(USER)["text"] and "art_girl" in c.last_panel(USER)["text"], "итог заявки")
    c.press(USER, "Отправить на проверку")
    card = card_of(c, ADMIN1)
    check("новый художник" in card["text"] and "комиксов" in card["text"], "карточка заявки на художника")
    press_card(c, ADMIN1, "Добавить")
    check(c.pg.query("SELECT name, link FROM artists WHERE name = 'Новая Художница'") ==
          [("Новая Художница", "https://t.me/art_girl")], "художник в справочнике")
    check(any("добавлен" in t for t in c.texts(USER)), "отправитель уведомлён")
    # братуха с псевдонимами, затем он находится по псевдониму
    c.say(USER, "/start")
    c.press(USER, "Предложить братуху")
    c.say(USER, "Дядя Миша")
    c.say(USER, "михалыч, дядь миш")
    c.press(USER, "Пропустить")
    c.press(USER, "Отправить на проверку")
    press_card(c, ADMIN2, "Добавить")
    check(c.pg.query("SELECT aliases, search, tag FROM characters WHERE name = 'Дядя Миша'") ==
          [("михалыч, дядь миш", "дядя миша\nмихалыч, дядь миш", "Дядя_Миша")], "герой с псевдонимами")
    # админ добавляет без проверки
    n_cards = len([1 for (mt, b) in WORLD.calls if mt == "sendMessage" and b["chat_id"] == ADMIN1 and "Заявка #" in b["text"]])
    c.say(ADMIN1, "/start")
    c.press(ADMIN1, "Предложить братуху")
    c.say(ADMIN1, "Братуха Админа")
    c.press(ADMIN1, "Пропустить")
    c.press(ADMIN1, "Пропустить")
    c.press(ADMIN1, "Отправить на проверку")
    check(c.pg.query("SELECT count(*) FROM characters WHERE name = 'Братуха Админа'")[0][0] == 1, "автоодобрение админа")
    n_after = len([1 for (mt, b) in WORLD.calls if mt == "sendMessage" and b["chat_id"] == ADMIN1 and "Заявка #" in b["text"]])
    check(n_after == n_cards, "карточка для автоодобренной заявки не рассылается")


@scenario
def own_and_unknown_artist(c):
    c.start()
    seed_basic(c)
    c.say(USER, "/start")
    c.press(USER, "Предложить работу")
    c.photo(USER)
    c.press(USER, "Дальше")
    c.press(USER, "Это моя работа")
    c.press(USER, "Использовать моё имя")
    c.press(USER, "Моя ссылка")
    check("Кто изображён" in c.last_panel(USER)["text"], "после ссылки идём к братухам")
    c.press(USER, "Дальше")
    c.press(USER, "Пропустить")
    c.press(USER, "Остаться анонимом")
    c.press(USER, "Отправить на проверку")
    check("сам автор" in card_of(c, ADMIN1)["text"], "админ видит, что автор — отправитель")
    press_card(c, ADMIN1, "Опубликовать")
    check(c.pg.query("SELECT name, link, tg_id FROM artists WHERE name = 'Вася'") ==
          [("Вася", "https://t.me/vasya", USER)], "художник привязан к пользователю")
    # во второй раз «моя работа» выбирает уже существующего художника
    c.say(USER, "/start")
    c.press(USER, "Предложить работу")
    c.photo(USER)
    c.press(USER, "Дальше")
    c.press(USER, "Это моя работа")
    check("Вася" in c.last_panel(USER)["text"] and "Кто автор" in c.last_panel(USER)["text"], "автор подставлен")
    c.press(USER, "Автор неизвестен")
    c.press(USER, "Дальше")
    c.press(USER, "Дальше")
    c.press(USER, "Пропустить")
    c.press(USER, "Остаться анонимом")
    c.press(USER, "Отправить на проверку")
    press_card(c, ADMIN1, "Опубликовать")
    check("неизвестен" in c.channel_posts()[-1][1]["caption"], "подпись «неизвестен»")


@scenario
def navigation(c):
    c.start()
    seed_basic(c)
    c.say(USER, "/start")
    c.press(USER, "Предложить работу")
    c.press(USER, "Отмена")
    check("Что делаем" in c.last_panel(USER)["text"], "отмена возвращает в меню")
    check(c.pg.query("SELECT count(*) FROM requests")[0][0] == 0, "черновик удалён")
    c.press(USER, "Предложить работу")
    c.press_data(USER, "w:next:2:w_media")
    check("Сначала пришли" in last_alert(c), "без содержимого дальше нельзя: %r" % last_alert(c))
    c.photo(USER)
    c.press(USER, "Дальше")
    c.press_data(USER, "w:next:2:w_artist")
    check("Выбери художника" in last_alert(c), "без художника дальше нельзя")
    c.pick(USER, "Борис")
    c.press(USER, "Дальше")
    # двойное нажатие «Назад» и «Дальше» не перескакивает через экран и не удаляет черновик
    panel = c.last_panel(USER)
    back = next(b["callback_data"] for row in panel["markup"]["inline_keyboard"] for b in row if "Назад" in b["text"])
    c.press_data(USER, back, panel)
    c.press_data(USER, back, panel)
    check("устарела" in last_alert(c), "повторное «Назад»: %r" % last_alert(c))
    check("Кто автор" in c.last_panel(USER)["text"], "назад на шаг художника")
    check(c.pg.query("SELECT count(*) FROM requests")[0][0] == 1, "черновик не удалён двойным нажатием")
    panel = c.last_panel(USER)
    nxt = next(b["callback_data"] for row in panel["markup"]["inline_keyboard"] for b in row if "Дальше" in b["text"])
    c.press_data(USER, nxt, panel)
    c.press_data(USER, nxt, panel)
    check("устарела" in last_alert(c) and "Кто изображён" in c.last_panel(USER)["text"], "повторное «Дальше»")
    c.press(USER, "Дальше")
    c.say(USER, "первая подпись")
    c.press(USER, "Остаться анонимом")
    check("первая подпись" in c.last_panel(USER)["text"], "предпросмотр")
    c.say(USER, "ок")
    check("Так будет выглядеть" in c.last_panel(USER)["text"], "лишний текст перерисовывает экран, а не меню")
    check(c.pg.query("SELECT status FROM requests") == [("draft",)], "черновик на месте")
    c.photo(USER, "PH2")
    check("Так будет выглядеть" in c.last_panel(USER)["text"], "лишнее фото тоже не сбрасывает мастер")
    c.press(USER, "Изменить")
    c.press(USER, "Подпись")
    c.say(USER, "вторая подпись")
    check("вторая подпись" in c.last_panel(USER)["text"] and "Так будет выглядеть" in c.last_panel(USER)["text"],
          "после правки возврат к просмотру")
    c.say(USER, "/cancel")
    check("Что делаем" in c.last_panel(USER)["text"], "/cancel возвращает в меню")
    check(c.pg.query("SELECT count(*) FROM requests WHERE status = 'draft'")[0][0] == 0, "черновик удалён командой")


@scenario
def mixed_media(c):
    c.start()
    seed_basic(c)
    c.say(USER, "/start")
    c.press(USER, "Предложить работу")
    c.photo(USER)
    c.say(USER, document={"file_id": "DOC1"})
    check("смешивать нельзя" in c.texts(USER)[-1], "файл к фото не добавить")
    c.say(USER, animation={"file_id": "GIF1"}, document={"file_id": "GIF1"})
    check("смешивать нельзя" in c.texts(USER)[-1], "GIF к фото не добавить")
    c.press(USER, "Очистить")
    c.say(USER, animation={"file_id": "GIF1"}, document={"file_id": "GIF1"})
    check("Принято: <b>1</b>" in c.last_panel(USER)["text"], "GIF по одному принимается")
    c.say(USER, sticker={"file_id": "ST"})
    check("не принимаю" in c.texts(USER)[-1], "стикер не поддерживается")


@scenario
def restart_midway(c):
    c.start()
    seed_basic(c)
    c.say(USER, "/start")
    c.press(USER, "Предложить работу")
    c.photo(USER)
    c.restart()
    c.press(USER, "Дальше")
    check("Кто автор" in c.last_panel(USER)["text"], "черновик пережил перезапуск")
    c.pick(USER, "Борис")
    check("Борис" in c.last_panel(USER)["text"], "выбор после перезапуска")


@scenario
def inline_misc(c):
    c.start()
    c.seed(characters=[("Братуха %02d" % i, "") for i in range(60)])
    ans = c.inline(USER, "")
    check([r["title"] for r in ans["results"]] == ["Сначала открой меню бота"], "без шага — подсказка")
    c.pick(USER, "/start")
    check("Что делаем" in c.last_panel(USER)["text"], "пункт-подсказка открывает меню")
    c.say(USER, "/start")
    c.press(USER, "Предложить работу")
    c.photo(USER)
    c.press(USER, "Дальше")
    c.pick(USER, "➕ Нет в списке")
    c.say(USER, "Х")
    c.press(USER, "Пропустить")
    check("Кто изображён" in c.last_panel(USER)["text"], "переход к братухам")
    first = c.inline(USER, "")
    check(len(first["results"]) == 50 and first["next_offset"] == "49", "первая порция: %d, next=%r" %
          (len(first["results"]), first.get("next_offset")))
    second = c.inline(USER, "", offset=first["next_offset"])
    ids = [r["id"] for r in first["results"] + second["results"]]
    check(len(set(ids)) == len(ids) == 61 and second["next_offset"] == "", "вторая порция добирает остаток")
    grp = {"id": "iqg", "from": c.frm(USER), "query": "", "offset": "", "chat_type": "supergroup"}
    WORLD.enqueue("inline_query", grp)
    WORLD.settle()
    check(c.inline_answer("iqg")["results"] == [], "в группах список не показывается")


def calls(method):
    return [b for (mt, b) in WORLD.calls if mt == method]


@scenario
def banners(c):
    c.start()
    seed_basic(c)

    # меню: первый раз картинка уходит файлом, дальше — по file_id
    c.say(USER, "/start")
    menu = c.last_panel(USER)
    check(menu["method"] == "sendPhoto" and menu["banner"] == "menu", "меню — баннер: %r" % menu["banner"])
    check("42 CONFESSION" in menu["text"] and menu["body"]["parse_mode"] == "HTML", "текст меню в подписи")
    check(len(WORLD.uploads) == 1 and WORLD.uploads[0]["name"] == "menu.jpg", "первый раз файл ушёл формой")
    jpeg = WORLD.uploads[0]["data"]
    check(jpeg[:3] == b"\xff\xd8\xff" and len(jpeg) > 10000, "в форме настоящий JPEG, а не пустышка: %d байт" % len(jpeg))
    c.say(USER2, "/start")
    check(len(WORLD.uploads) == 1 and c.last_panel(USER2)["banner"] == "menu", "второму пользователю — по file_id")

    # другой экран: то же сообщение, картинка заменяется на месте
    c.press(USER, "Предложить работу")
    media = c.last_panel(USER)
    check(media["id"] == menu["id"] and media["banner"] == "media" and "Новая работа" in media["text"],
          "баннер сменился на месте")
    check(len(calls("editMessageMedia")) == 1 and len(WORLD.uploads) == 2, "новая картинка ушла в editMessageMedia")
    c.photo(USER, "PH1")
    check(len(c.panels(USER)) == 1 and c.last_panel(USER)["banner"] == "media" and len(WORLD.uploads) == 2,
          "после фото панель пришла заново, но уже по file_id")

    # тот же баннер: правится только подпись
    c.press(USER, "Дальше")
    c.pick(USER, "Борис")
    c.press(USER, "Дальше")
    c.pick(USER, "Лёнька")
    before = c.last_panel(USER)
    edits = len(calls("editMessageCaption"))
    c.press(USER, "✖ Лёнька")
    after = c.last_panel(USER)
    check(after["id"] == before["id"] and after["banner"] == "chars", "баннер братух остался")
    check(len(calls("editMessageCaption")) == edits + 1 and "пока никого" in after["text"], "правка подписи без картинки")

    # просмотр поста — без баннера: панель из фото становится текстом и обратно
    c.press(USER, "Дальше")
    c.press(USER, "Пропустить")
    check(c.last_panel(USER)["banner"] == "credit", "экран подписи отправителя")
    c.press(USER, "Остаться анонимом")
    review = c.last_panel(USER)
    check(review["method"] == "sendMessage" and review["banner"] is None and "Так будет выглядеть пост" in review["text"],
          "просмотр поста без баннера")
    check(len(c.panels(USER)) == 1, "старая панель удалена")
    c.press(USER, "Изменить")
    check(c.last_panel(USER)["banner"] == "edit" and len(c.panels(USER)) == 1, "меню правки с баннером")
    c.press(USER, "К просмотру")
    check(c.last_panel(USER)["method"] == "sendMessage" and len(c.panels(USER)) == 1, "обратно к тексту")
    c.press(USER, "Отправить на проверку")
    check(c.last_panel(USER)["banner"] == "sent", "подтверждение с баннером")
    check(card_of(c, ADMIN1)["method"] == "sendMessage" and not card_of(c, ADMIN1)["banner"], "карточка админа текстом")

    # причина отказа и итоговые уведомления
    press_card(c, ADMIN1, "Отклонить")
    check(c.last_panel(ADMIN1)["banner"] == "reason", "запрос причины с баннером")
    c.say(ADMIN1, "Не подходит")
    rejected = [m for m in WORLD.messages.values() if m["chat"] == str(USER) and m.get("banner") == "rejected"]
    check(len(rejected) == 1 and "Не подходит" in rejected[0]["text"], "отказ пришёл с баннером")
    new_work(c)
    press_card(c, ADMIN1, "Опубликовать")
    approved = [m for m in WORLD.messages.values() if m["chat"] == str(USER) and m.get("banner") == "approved"]
    check(len(approved) == 1 and "опубликована" in approved[0]["text"], "одобрение пришло с баннером")
    check(len(c.channel_posts()) == 1 and all(not b.get("_banner") for _, b in c.channel_posts()),
          "в канал баннеры не попадают")
    check(c.bot.log.count("editMessageText: Bad Request: there is no text in the message to edit") == 0,
          "текст у фото-сообщения не правится: %s" % c.bot.log[-5:])


@scenario
def banner_recovery(c):
    c.start()
    c.say(USER, "/start")
    fid = c.last_panel(USER)["body"]["photo"]
    # Telegram перестал принимать сохранённый file_id: бот загружает файл заново и дальше работает с новым
    WORLD.bad_files.add(fid)
    c.say(USER2, "/start")
    check(len(WORLD.uploads) == 2 and c.last_panel(USER2)["banner"] == "menu", "после отказа файл загружен заново")
    new_fid = c.last_panel(USER2)["body"]["photo"]
    check(new_fid != fid, "выдан новый file_id")
    c.say(ADMIN2, "/start")
    check(len(WORLD.uploads) == 2 and c.last_panel(ADMIN2)["body"]["photo"] == new_fid, "дальше — по новому file_id")


@scenario
def banners_missing(c):
    empty = tempfile.mkdtemp()
    c.start(BANNERS_DIR=empty)
    check(c.bot.wait_log("нет баннеров", 10) and c.bot.wait_log("Бот запущен", 10), "предупреждение при старте: %s" % c.bot.log)
    c.say(USER, "/start")
    menu = c.last_panel(USER)
    check(menu["method"] == "sendMessage" and not menu["banner"] and "Что делаем" in menu["text"],
          "без файлов экран приходит обычным текстом")
    c.press(USER, "Предложить работу")
    check("Новая работа" in c.last_panel(USER)["text"] and len(c.panels(USER)) == 1, "мастер работает без баннеров")
    check(WORLD.uploads == [], "ничего не загружалось")


def main():
    binary = sys.argv[1]
    only = set(sys.argv[2:])
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeBotApi)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    pg = Postgres()
    failures = []
    try:
        for fn in SCENARIOS:
            if only and fn.__name__ not in only:
                continue
            WORLD.reset()
            pg.reset()
            c = Ctx(binary, pg)
            c.api_url = "http://127.0.0.1:%d" % server.server_address[1]
            try:
                fn(c)
                print("ok    " + fn.__name__)
            except Exception:
                failures.append(fn.__name__)
                print("FAIL  " + fn.__name__)
                traceback.print_exc()
                if c.bot:
                    print("      stderr бота:", *c.bot.log[-15:], sep="\n        ")
                print("      ответы на кнопки:", [a.get("text") for a in WORLD.cb_answers][-8:])
                print("      вызовы:", *["%s %s" % (mt, json.dumps(b, ensure_ascii=False, default=str)[:140])
                                         for mt, b in WORLD.calls[-6:]], sep="\n        ")
                try:
                    print("      users:", pg.query("SELECT id, state, req_id, ret, panel_msg FROM users ORDER BY id"))
                except Exception as e:  # схема могла не создаться
                    print("      users: недоступно:", e)
                for uid in (USER, ADMIN1):
                    print("      чат %d, последние сообщения бота:" % uid,
                          *[t.replace("\n", " / ")[:150] for t in c.texts(uid)[-4:]], sep="\n        ")
            finally:
                if c.bot:
                    c.bot.stop()
    finally:
        server.shutdown()
        pg.close()
    if failures:
        sys.exit("Не прошло сценариев: %d (%s)" % (len(failures), ", ".join(failures)))
    print("Все сценарии прошли")


if __name__ == "__main__":
    main()
