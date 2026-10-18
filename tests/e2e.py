# /// script
# requires-python = ">=3.10"
# ///
"""Сквозная проверка бота на поддельном Bot API.

Поднимает локальный сервер, который отвечает как Telegram (getUpdates,
sendMessage), запускает настоящий бинарник бота и сверяет его ответы.

    uv run --script tests/e2e.py build/tgbot
"""
import json
import os
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs

TOKEN = "123456:TEST"
GROUP = -1001234567890  # отрицательный и длиннее 32 бит, как id супергрупп


def message(update_id, chat_id, text=None):
    msg = {"message_id": update_id, "chat": {"id": chat_id, "type": "private"}, "date": 0}
    if text is not None:
        msg["text"] = text
    return {"update_id": update_id, "message": msg}


UPDATES: list[dict[str, Any]] = [
    message(100, 111, "/start"),
    message(101, 111, "просто текст"),
    message(102, GROUP, "/start@some_bot"),
    message(103, 111, "/startfoo"),
    message(104, 111),  # без текста: фото, стикер и т. п.
    {"update_id": 105, "edited_message": {"message_id": 1, "chat": {"id": 111}, "text": "/start"}},
    message(106, 222, "/start с аргументами"),
]
EXPECTED_REPLIES = [(111, "привет"), (GROUP, "привет"), (222, "привет")]
NEXT_OFFSET = 107


class FakeBotApi(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    polls = []    # параметры каждого getUpdates
    replies = []  # (chat_id, text) из каждого sendMessage

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
        form = parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        prefix = f"/bot{TOKEN}/"
        if not self.path.startswith(prefix):
            return self.respond(401, {"ok": False, "error_code": 401, "description": "Unauthorized"})

        method = self.path[len(prefix):]
        if method == "getUpdates":
            offset = int(form["offset"][0])
            self.polls.append({
                "offset": offset,
                "timeout": int(form["timeout"][0]),
                "allowed_updates": json.loads(form["allowed_updates"][0]),
            })
            pending = [u for u in UPDATES if u["update_id"] >= offset]
            if not pending:
                time.sleep(0.3)  # имитация long polling
            self.respond(200, {"ok": True, "result": pending})
        elif method == "sendMessage":
            self.replies.append((int(form["chat_id"][0]), form["text"][0]))
            self.respond(200, {"ok": True, "result": {"message_id": 1}})
        else:
            self.respond(404, {"ok": False, "error_code": 404, "description": "Not Found"})


class Bot:
    def __init__(self, binary, token, api_url):
        env = {k: v for k, v in os.environ.items() if not k.lower().endswith("_proxy")}
        env.pop("BOT_TOKEN", None)
        if token is not None:
            env["BOT_TOKEN"] = token
        env["TELEGRAM_API_URL"] = api_url
        self.proc = subprocess.Popen([binary], env=env, stderr=subprocess.PIPE, text=True)
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


def wait_until(predicate, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return False


def main():
    binary = sys.argv[1]
    server = ThreadingHTTPServer(("127.0.0.1", 0), FakeBotApi)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    api_url = f"http://127.0.0.1:{server.server_address[1]}"
    failures = []

    def check(name, condition, bot=None):
        print(("ok    " if condition else "FAIL  ") + name)
        if not condition:
            failures.append(name)
            if bot:
                print("      stderr бота:", *bot.log, sep="\n        ")

    # 1. Рабочий токен: ответы, подтверждение update через offset, параметры long polling.
    bot = Bot(binary, TOKEN, api_url)
    wait_until(lambda: len(FakeBotApi.replies) >= len(EXPECTED_REPLIES), 10)
    time.sleep(1)  # за это время бот сделает ещё несколько getUpdates: дублей быть не должно
    polls = list(FakeBotApi.polls)
    check("ответы на /start, и только на него", FakeBotApi.replies == EXPECTED_REPLIES, bot)
    check("первый getUpdates с offset=0", bool(polls) and polls[0]["offset"] == 0, bot)
    check("update подтверждены: offset = последний update_id + 1", bool(polls) and polls[-1]["offset"] == NEXT_OFFSET, bot)
    check("timeout=30 и allowed_updates=[message]",
          bool(polls) and all(p["timeout"] == 30 and p["allowed_updates"] == ["message"] for p in polls), bot)
    check("завершение по SIGTERM", bot.stop() == -signal.SIGTERM, bot)

    # 2. Неверный токен: ошибка Telegram попадает в лог, бот продолжает работать.
    bot = Bot(binary, "bad-token", api_url)
    check("ошибка Unauthorized в логе", bot.wait_log("Unauthorized", 5), bot)
    check("бот не падает после ошибки", bot.proc.poll() is None, bot)
    bot.stop()

    # 3. Токен не задан: сразу выход с кодом 1.
    bot = Bot(binary, None, api_url)
    check("без BOT_TOKEN выход с кодом 1", bot.proc.wait(timeout=5) == 1 and bot.wait_log("BOT_TOKEN", 1), bot)

    server.shutdown()
    if failures:
        sys.exit(f"Не прошло проверок: {len(failures)}")
    print("Все проверки прошли")


if __name__ == "__main__":
    main()
