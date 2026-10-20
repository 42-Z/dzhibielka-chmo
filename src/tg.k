// tg.k: Bot API поверх libcurl.
//
// Каждый запрос — POST с телом JSON. tg_post забирает дерево jansson и сам его
// освобождает. Все тексты бота уходят с parse_mode=HTML, поэтому всё, что пришло
// от пользователей, нужно пропускать через sb_html.

tg_curl;      // дескриптор libcurl: один на все запросы, соединение переиспользуется
tg_token;     // токен бота (BOT_TOKEN)
tg_base;      // адрес Bot API: постоянный, из окружения не берётся
tg_hdr;       // список заголовков с Content-Type: application/json
tg_last_err;  // описание последней ошибки Telegram (строка на арене, или 0)

tg_init(token) {
    tg_token = token;
    tg_base = "https://api.telegram.org";
    curl_global_init(3);  // CURL_GLOBAL_DEFAULT
    tg_curl = curl_easy_init();
    tg_hdr = curl_slist_append(0, "Content-Type: application/json");
    (tg_curl != 0) & (tg_hdr != 0);
}

// Истина, если последняя ошибка Telegram содержит sub.
tg_err_has(sub) {
    if !tg_last_err return 0;
    s_has(tg_last_err, sub);
}

// Выполняет запрос к Bot API: тело — JSON-текст body либо multipart-форма mime (одно из
// двух; mime после запроса освобождается). Возвращает разобранный ответ с ok=true
// (освободить через json_release), при любой ошибке пишет причину в stderr, запоминает
// её в tg_last_err и возвращает 0.
tg_run(method, body, mime, timeout) {
    auto url;
    auto out;
    auto resp;
    auto size;
    auto rc;
    auto root;
    auto desc;

    tg_last_err = 0;
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

    // Форму собирают на дескрипторе, который уже сброшен (mime_new), поэтому здесь не сбрасываем.
    if !mime curl_easy_reset(tg_curl);
    curl_easy_setopt(tg_curl, 10002, sb_str(url));  // CURLOPT_URL
    if mime curl_easy_setopt(tg_curl, 10269, mime); // CURLOPT_MIMEPOST: multipart/form-data
    else {
        curl_easy_setopt(tg_curl, 10015, body);     // CURLOPT_POSTFIELDS
        curl_easy_setopt(tg_curl, 10023, tg_hdr);   // CURLOPT_HTTPHEADER
    }
    curl_easy_setopt(tg_curl, 10001, out);          // CURLOPT_WRITEDATA: без WRITEFUNCTION libcurl пишет в FILE* через fwrite
    curl_easy_setopt(tg_curl, 78, 10);              // CURLOPT_CONNECTTIMEOUT
    curl_easy_setopt(tg_curl, 13, timeout);         // CURLOPT_TIMEOUT
    // Прокси не настраивается: пустая строка отключает прокси из окружения (all_proxy и т. п.).
    curl_easy_setopt(tg_curl, 10004, "");           // CURLOPT_PROXY
    rc = curl_easy_perform(tg_curl) & 0xFFFFFFFF;
    fclose(out);  // фиксирует размер и завершающий нуль в resp
    if mime curl_mime_free(mime);

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

// Вызывает метод Bot API с JSON-телом: req — дерево jansson, tg_post забирает его
// и освобождает. Результат и ошибки — как у tg_run.
tg_post(method, req, timeout) {
    auto body;
    body = jdump(req);
    json_release(req);
    if !body {
        tg_last_err = 0;
        fprintf(stderr, "%s: запрос не собран\n", method);
        return 0;
    }
    tg_run(method, body, 0, timeout);
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

// Вызовы для канала CHANNEL_ID. Он бывает «@имя», а tg_send переводит chat в число, поэтому
// здесь chat_id передаётся строкой.
tg_chan_send(html) {
    auto req;
    auto root;
    auto id;
    req = jsets(jo(), "chat_id", cfg_channel);
    jsets(req, "text", html);
    jsets(req, "parse_mode", "HTML");
    jset(req, "link_preview_options", jsetb(jo(), "is_disabled", 1));
    root = tg_post("sendMessage", req, 15);
    if !root return 0;
    id = jint(jget(root, "result"), "message_id");
    json_release(root);
    id;
}

// Истина, если Telegram принял правку текста сообщения в канале.
tg_chan_edit(mid, html) {
    auto req;
    auto root;
    req = jseti(jsets(jo(), "chat_id", cfg_channel), "message_id", mid);
    jsets(req, "text", html);
    jsets(req, "parse_mode", "HTML");
    jset(req, "link_preview_options", jsetb(jo(), "is_disabled", 1));
    root = tg_post("editMessageText", req, 15);
    json_release(root);
    root != 0;
}

tg_chan_delete(mid) {
    auto root;
    root = tg_post("deleteMessage", jseti(jsets(jo(), "chat_id", cfg_channel), "message_id", mid), 15);
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

// --- баннеры -------------------------------------------------------------------
//
// Баннер — картинка assets/banners/<имя>.jpg над текстом сообщения, то есть фото с
// подписью (до 1024 символов). Первый раз файл уходит в Telegram формой multipart, в
// ответе приходит file_id; он хранится в памяти до перезапуска, и дальше баннер
// отправляется по file_id обычным JSON-запросом. Функции ниже клавиатуру (markup)
// только читают: она остаётся у вызывающего, который её и освобождает.

tg_pics;        // каталог с баннерами: постоянный, из окружения не берётся
bn_name[32];    // имена уже загруженных баннеров
bn_fid[32];     // их file_id (0 — Telegram перестал его принимать)
bn_n;

// Номер записи баннера, начиная с единицы, или 0.
bn_find(name) {
    auto i;
    for i = 0 i < bn_n i++ {
        if s_eq(bn_name[i], name) return i + 1;
    }
    0;
}

bn_get(name) {
    auto i;
    i = bn_find(name);
    if i return bn_fid[i - 1];
    0;
}

bn_put(name, fid) {
    auto i;
    i = bn_find(name);
    if i {
        free(bn_fid[i - 1]);
        bn_fid[i - 1] = strdup(fid);
        return 0;
    }
    if bn_n >= 32 return 0;
    bn_name[bn_n] = strdup(name);
    bn_fid[bn_n] = strdup(fid);
    bn_n++;
}

// Забывает file_id баннера, который Telegram не принял.
bn_drop(name) {
    auto i;
    i = bn_find(name);
    if !i return 0;
    free(bn_fid[i - 1]);
    bn_fid[i - 1] = 0;
}

pic_path(name) {
    auto b;
    b = sb_add(sb_new(), tg_pics);
    sb_c(b, '/');
    sb_add(b, name);
    sb_add(b, ".jpg");
    sb_str(b);
}

// Истина, если файл баннера есть на диске.
pic_exists(name) {
    auto f;
    f = fopen(pic_path(name), "r");
    if !f return 0;
    fclose(f);
    1;
}

// file_id фото из сообщения Telegram: размеры идут по возрастанию, берём последний.
msg_pic_id(msg) {
    auto sizes;
    auto n;
    sizes = jget(msg, "photo");
    n = json_array_size(sizes);
    if n == 0 return 0;
    jstr(json_array_get(sizes, n - 1), "file_id");
}

// Запоминает file_id баннера из ответа Telegram.
pic_remember(name, msg) {
    auto fid;
    fid = msg_pic_id(msg);
    if fid bn_put(name, fid);
}

// Telegram больше не принимает сохранённый file_id: файл надо загрузить заново.
tg_stale_file() tg_err_has("file identifier");

// Пустая multipart-форма. Дескриптор сбрасывается заранее: tg_run после этого его не трогает.
mime_new() {
    curl_easy_reset(tg_curl);
    curl_mime_init(tg_curl);
}

mime_text(mime, name, value) {
    auto part;
    part = curl_mime_addpart(mime);
    curl_mime_name(part, name);
    curl_mime_data(part, value, strlen(value));
}

mime_pic(mime, name, path) {
    auto part;
    part = curl_mime_addpart(mime);
    curl_mime_name(part, name);
    curl_mime_filedata(part, path);
    curl_mime_type(part, "image/jpeg");
}

// Сообщение-баннер: фото с подписью html (HTML) и клавиатурой markup (или 0).
// Возвращает message_id или 0 — нет файла баннера либо Telegram отказал.
tg_photo(chat, name, html, markup) {
    auto req;
    auto root;
    auto mime;
    auto id;
    auto fid;

    fid = bn_get(name);
    if fid {
        req = jsets(jsets(jsets(jseti(jo(), "chat_id", chat), "photo", fid), "caption", html), "parse_mode", "HTML");
        if markup jset(req, "reply_markup", jcopy(markup));
        root = tg_post("sendPhoto", req, 30);
        if root {
            id = jint(jget(root, "result"), "message_id");
            json_release(root);
            return id;
        }
        if !tg_stale_file() return 0;
        bn_drop(name);
    }
    if !pic_exists(name) return 0;
    mime = mime_new();
    mime_text(mime, "chat_id", s_itoa(chat));
    mime_text(mime, "caption", html);
    mime_text(mime, "parse_mode", "HTML");
    if markup mime_text(mime, "reply_markup", jdump(markup));
    mime_pic(mime, "photo", pic_path(name));
    root = tg_run("sendPhoto", 0, mime, 60);
    if !root return 0;
    id = jint(jget(root, "result"), "message_id");
    pic_remember(name, jget(root, "result"));
    json_release(root);
    id;
}

// Заменяет картинку, подпись и клавиатуру у сообщения-баннера (editMessageMedia).
// Истина, если Telegram принял правку.
tg_edit_pic(chat, mid, name, html, markup) {
    auto req;
    auto media;
    auto root;
    auto mime;
    auto fid;

    fid = bn_get(name);
    if fid {
        media = jsets(jsets(jsets(jsets(jo(), "type", "photo"), "media", fid), "caption", html), "parse_mode", "HTML");
        req = jset(jseti(jseti(jo(), "chat_id", chat), "message_id", mid), "media", media);
        if markup jset(req, "reply_markup", jcopy(markup));
        root = tg_post("editMessageMedia", req, 30);
        if root {
            json_release(root);
            return 1;
        }
        if !tg_stale_file() return 0;
        bn_drop(name);
    }
    if !pic_exists(name) return 0;
    media = jsets(jsets(jsets(jsets(jo(), "type", "photo"), "media", "attach://pic"), "caption", html), "parse_mode", "HTML");
    mime = mime_new();
    mime_text(mime, "chat_id", s_itoa(chat));
    mime_text(mime, "message_id", s_itoa(mid));
    mime_text(mime, "media", jdump(media));
    json_release(media);
    if markup mime_text(mime, "reply_markup", jdump(markup));
    mime_pic(mime, "pic", pic_path(name));
    root = tg_run("editMessageMedia", 0, mime, 60);
    if !root return 0;
    pic_remember(name, jget(root, "result"));
    json_release(root);
    1;
}

// Меняет подпись и клавиатуру сообщения-баннера, картинка остаётся прежней.
tg_edit_caption(chat, mid, html, markup) {
    auto req;
    auto root;
    req = jsets(jsets(jseti(jseti(jo(), "chat_id", chat), "message_id", mid), "caption", html), "parse_mode", "HTML");
    if markup jset(req, "reply_markup", jcopy(markup));
    root = tg_post("editMessageCaption", req, 15);
    json_release(root);
    root != 0;
}
