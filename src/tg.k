// tg.k: Bot API поверх libcurl.
//
// Каждый запрос — POST с телом JSON. tg_post забирает дерево jansson и сам его
// освобождает. Все тексты бота уходят с parse_mode=HTML, поэтому всё, что пришло
// от пользователей, нужно пропускать через sb_html.

tg_curl;      // дескриптор libcurl: один на все запросы, соединение переиспользуется
tg_token;     // токен бота (BOT_TOKEN)
tg_base;      // адрес Bot API (TELEGRAM_API_URL)
tg_hdr;       // список заголовков с Content-Type: application/json
tg_last_err;  // описание последней ошибки Telegram (строка на арене, или 0)

tg_init(token, base) {
    tg_token = token;
    tg_base = base;
    curl_global_init(3);  // CURL_GLOBAL_DEFAULT
    tg_curl = curl_easy_init();
    tg_hdr = curl_slist_append(0, "Content-Type: application/json");
    (tg_curl != 0) & (tg_hdr != 0);
}

// Вызывает метод Bot API. Возвращает разобранный ответ с ok=true (освободить через
// json_release), при любой ошибке пишет причину в stderr, запоминает её в
// tg_last_err и возвращает 0.
tg_post(method, req, timeout) {
    auto url;
    auto body;
    auto out;
    auto resp;
    auto size;
    auto rc;
    auto root;
    auto desc;

    tg_last_err = 0;
    body = jdump(req);
    json_release(req);
    if !body {
        fprintf(stderr, "%s: запрос не собран\n", method);
        return 0;
    }
    url = sb_new();
    sb_add(url, tg_base);
    sb_add(url, "/bot");
    sb_add(url, tg_token);
    sb_c(url, '/');
    sb_add(url, method);

    resp = 0;
    size = 0;
    out = open_memstream(&resp, &size);
    if !out die("не хватает памяти");

    curl_easy_reset(tg_curl);
    curl_easy_setopt(tg_curl, 10002, sb_str(url));  // CURLOPT_URL
    curl_easy_setopt(tg_curl, 10015, body);         // CURLOPT_POSTFIELDS
    curl_easy_setopt(tg_curl, 10023, tg_hdr);       // CURLOPT_HTTPHEADER
    curl_easy_setopt(tg_curl, 10001, out);          // CURLOPT_WRITEDATA: без WRITEFUNCTION libcurl пишет в FILE* через fwrite
    curl_easy_setopt(tg_curl, 78, 10);              // CURLOPT_CONNECTTIMEOUT
    curl_easy_setopt(tg_curl, 13, timeout);         // CURLOPT_TIMEOUT
    rc = curl_easy_perform(tg_curl) & 0xFFFFFFFF;
    fclose(out);  // фиксирует размер и завершающий нуль в resp

    if rc != 0 {
        tg_last_err = s_dup(curl_easy_strerror(rc));
        fprintf(stderr, "%s: %s\n", method, tg_last_err);
        free(resp);
        return 0;
    }

    root = json_loads(resp, 0, 0);
    free(resp);
    if jtrue(root, "ok") return root;

    // Telegram отвечает JSON с description и на ошибки; иначе это не его ответ (прокси, сбой сети).
    desc = jstr(root, "description");
    if !desc desc = "неожиданный ответ";
    tg_last_err = s_dup(desc);
    fprintf(stderr, "%s: %s\n", method, desc);
    json_release(root);
    0;
}

// Кнопки и клавиатуры: клавиатура — массив рядов, ряд — массив кнопок.
btn_cb(text, data) jsets(jsets(jo(), "text", text), "callback_data", data);

// Кнопка, открывающая выпадающий список (inline-режим) прямо в этом чате.
btn_pick(text) jsets(jsets(jo(), "text", text), "switch_inline_query_current_chat", "");

btn_url(text, url) jsets(jsets(jo(), "text", text), "url", url);

// Ряд из одной кнопки.
kb_row1(kb, b) jpush(kb, jpush(ja(), b));

// Ряд из двух кнопок.
kb_row2(kb, b1, b2) jpush(kb, jpush(jpush(ja(), b1), b2));

kb_markup(kb) jset(jo(), "inline_keyboard", kb);

// Отправляет текст (HTML); возвращает message_id или 0.
tg_send(chat, html, markup) {
    auto req;
    auto root;
    auto id;
    req = jseti(jo(), "chat_id", chat);
    jsets(req, "text", html);
    jsets(req, "parse_mode", "HTML");
    jset(req, "link_preview_options", jsetb(jo(), "is_disabled", 1));
    if markup jset(req, "reply_markup", markup);
    root = tg_post("sendMessage", req, 15);
    if !root return 0;
    id = jint(jget(root, "result"), "message_id");
    json_release(root);
    id;
}

// Меняет текст и клавиатуру сообщения. Истина, если Telegram принял правку.
tg_edit(chat, mid, html, markup) {
    auto req;
    auto root;
    req = jseti(jseti(jo(), "chat_id", chat), "message_id", mid);
    jsets(req, "text", html);
    jsets(req, "parse_mode", "HTML");
    jset(req, "link_preview_options", jsetb(jo(), "is_disabled", 1));
    if markup jset(req, "reply_markup", markup);
    root = tg_post("editMessageText", req, 15);
    json_release(root);
    root != 0;
}

tg_delete(chat, mid) {
    auto root;
    root = tg_post("deleteMessage", jseti(jseti(jo(), "chat_id", chat), "message_id", mid), 15);
    json_release(root);
    root != 0;
}

// Отвечает на нажатие кнопки (text можно передать 0); без ответа кнопка «крутится».
tg_ack(cbid, text) {
    auto req;
    auto root;
    req = jsets(jo(), "callback_query_id", cbid);
    if text jsets(req, "text", text);
    root = tg_post("answerCallbackQuery", req, 15);
    json_release(root);
    root != 0;
}

// То же, но текст показывается окном с кнопкой «ОК», а не всплывающей строкой: длинное
// объяснение за пару секунд не прочитать.
tg_alert(cbid, text) {
    auto req;
    auto root;
    req = jsetb(jsets(jsets(jo(), "callback_query_id", cbid), "text", text), "show_alert", 1);
    root = tg_post("answerCallbackQuery", req, 15);
    json_release(root);
    root != 0;
}
