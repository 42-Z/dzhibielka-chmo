// Telegram-бот: на команду /start отвечает «привет».
//
// Обновления приходят через long polling (getUpdates). HTTP выполняет libcurl,
// JSON разбирает jansson. В Kiva нет типов: всё — 64-битные слова, поэтому
// константы libcurl записаны числами, а указатели передаются как есть.
// Операторов && и || в языке пока нет: условия собираются через & и |
// над сравнениями в скобках.

extern getenv
extern free
extern sleep
extern fclose
extern fprintf
extern stderr
extern strlen
extern strncmp
extern asprintf
extern open_memstream
extern curl_global_init
extern curl_easy_init
extern curl_easy_reset
extern curl_easy_setopt
extern curl_easy_perform
extern curl_easy_getinfo
extern curl_easy_strerror
extern curl_easy_escape
extern curl_free
extern json_loads
extern json_delete
extern json_equal
extern json_true
extern json_object_get
extern json_array_get
extern json_array_size
extern json_integer_value
extern json_string_value

tg_curl;   // дескриптор libcurl: один на все запросы, соединение переиспользуется
tg_token;  // токен бота (BOT_TOKEN)
tg_base;   // адрес Bot API (TELEGRAM_API_URL)

// Значение переменной окружения; пустая строка считается незаданной.
env_or(name, fallback) {
    auto v;
    v = getenv(name);
    if !v return fallback;
    if @8 *v == 0 return fallback;
    v;
}

// Освобождает корень дерева jansson (можно передать 0). json_decref в jansson.h
// объявлен inline и в библиотеке не экспортируется; для единственной ссылки,
// которую вернул json_loads, он сводится к json_delete.
json_release(root)
    if root json_delete(root);

// Вызывает метод Bot API (POST, application/x-www-form-urlencoded).
// Возвращает разобранный ответ с ok=true (освободить через json_release),
// при любой ошибке пишет причину в stderr и возвращает 0.
tg_call(method, body, timeout) {
    auto url;
    auto out;
    auto resp;
    auto size;
    auto rc;
    auto root;
    auto http;
    auto desc;

    url = 0;
    asprintf(&url, "%s/bot%s/%s", tg_base, tg_token, method);
    resp = 0;
    size = 0;
    out = open_memstream(&resp, &size);
    if !url | !out {
        fprintf(stderr, "%s: не хватает памяти\n", method);
        if out {
            fclose(out);
            free(resp);
        }
        free(url);
        return 0;
    }

    curl_easy_reset(tg_curl);
    curl_easy_setopt(tg_curl, 10002, url);   // CURLOPT_URL
    curl_easy_setopt(tg_curl, 10015, body);  // CURLOPT_POSTFIELDS
    curl_easy_setopt(tg_curl, 10001, out);   // CURLOPT_WRITEDATA: без WRITEFUNCTION libcurl пишет в FILE* через fwrite
    curl_easy_setopt(tg_curl, 78, 10);       // CURLOPT_CONNECTTIMEOUT
    curl_easy_setopt(tg_curl, 13, timeout);  // CURLOPT_TIMEOUT
    rc = curl_easy_perform(tg_curl) & 0xFFFFFFFF;
    fclose(out);  // фиксирует размер и завершающий нуль в resp
    free(url);

    if rc != 0 {
        fprintf(stderr, "%s: %s\n", method, curl_easy_strerror(rc));
        free(resp);
        return 0;
    }

    root = json_loads(resp, 0, 0);
    free(resp);
    if json_equal(json_object_get(root, "ok"), json_true()) & 0xFFFFFFFF return root;

    // Telegram отвечает JSON с description и на ошибки; иначе это не его ответ (прокси, сбой сети).
    http = 0;
    curl_easy_getinfo(tg_curl, 2097154, &http);  // CURLINFO_RESPONSE_CODE
    desc = json_string_value(json_object_get(root, "description"));
    if !desc desc = "неожиданный ответ";
    fprintf(stderr, "%s: HTTP %ld: %s\n", method, http, desc);
    json_release(root);
    0;
}

// Отправляет текстовое сообщение; текст экранируется для urlencoded-формы.
tg_send_message(chat, text) {
    auto esc;
    auto body;
    auto root;

    esc = curl_easy_escape(tg_curl, text, 0);
    if !esc return 0;
    body = 0;
    asprintf(&body, "chat_id=%lld&text=%s", chat, esc);
    curl_free(esc);
    if !body return 0;
    root = tg_call("sendMessage", body, 15);
    free(body);
    if !root return 0;
    json_release(root);
    1;
}

// Истина, если text — команда cmd (например "/start"): после имени идёт конец
// строки, пробел или @имя_бота.
tg_is_command(text, cmd) {
    auto n;
    auto c;
    n = strlen(cmd);
    if strncmp(text, cmd, n) & 0xFFFFFFFF return 0;
    c = @8 *(text + n);
    (c == 0) | (c == ' ') | (c == '\n') | (c == '@');
}

// Реагирует на сообщение. msg равно 0, если в update нет поля message.
tg_on_message(msg) {
    auto text;
    auto chat;

    if !msg return 0;
    text = json_string_value(json_object_get(msg, "text"));
    if !text return 0;
    chat = json_integer_value(json_object_get(json_object_get(msg, "chat"), "id"));
    if tg_is_command(text, "/start") tg_send_message(chat, "привет");
    0;
}

// Обрабатывает один update; возвращает offset для следующего getUpdates.
tg_handle_update(upd, offset) {
    auto id;

    id = json_integer_value(json_object_get(upd, "update_id"));
    tg_on_message(json_object_get(upd, "message"));
    if id >= offset return id + 1;
    offset;
}

global main
main() {
    auto offset;
    auto body;
    auto root;
    auto updates;
    auto n;
    auto i;

    tg_token = env_or("BOT_TOKEN", 0);
    if !tg_token {
        fprintf(stderr, "Не задана переменная окружения BOT_TOKEN (см. .env.example)\n");
        return 1;
    }
    tg_base = env_or("TELEGRAM_API_URL", "https://api.telegram.org");

    curl_global_init(3);  // CURL_GLOBAL_DEFAULT
    tg_curl = curl_easy_init();
    if !tg_curl {
        fprintf(stderr, "Не удалось инициализировать libcurl\n");
        return 1;
    }

    fprintf(stderr, "Бот запущен, жду сообщения (Ctrl+C — выход)\n");
    offset = 0;
    while 1 {
        // offset подтверждает обработанные update: Telegram не отдаёт их повторно.
        // allowed_updates=["message"] — остальные типы update боту не нужны.
        body = 0;
        asprintf(&body, "offset=%lld&timeout=30&allowed_updates=%%5B%%22message%%22%%5D", offset);
        root = 0;
        if body root = tg_call("getUpdates", body, 40);
        free(body);
        if !root {
            sleep(5);
            continue;
        }

        updates = json_object_get(root, "result");
        n = json_array_size(updates);
        for i = 0 i < n i++ {
            offset = tg_handle_update(json_array_get(updates, i), offset);
        }
        json_release(root);
    }
}
