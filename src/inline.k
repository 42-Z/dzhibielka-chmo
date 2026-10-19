// inline.k: выпадающий список (inline-режим) для выбора художника и братух.
//
// Что показывать, определяет шаг пользователя в БД, а не текст запроса: на шаге
// «художник» — художники, на шаге «братухи» — братухи. Выбранный пункт Telegram
// отправляет в чат сообщением через бота с точным именем в тексте — его разбирает
// on_pick (user.k). Поиск — по подстроке в ключе name_key/search (нижний регистр).

// Пункт списка: id результата, заголовок, описание; текст сообщения — само имя.
inline_item(id, title, desc, text) {
    auto o;
    o = jsets(jsets(jo(), "type", "article"), "id", id);
    jsets(o, "title", title);
    if @8 *desc != 0 jsets(o, "description", desc);
    jset(o, "input_message_content", jsets(jo(), "message_text", text));
    o;
}

inline_id(prefix, n) sb_str(sb_int(qb(prefix), n));

// Ответ на inline-запрос: results — массив, next — смещение для следующей порции.
inline_answer(qid, results, next) {
    auto req;
    req = jsets(jo(), "inline_query_id", qid);
    jset(req, "results", results);
    jseti(req, "cache_time", 0);
    jsetb(req, "is_personal", 1);
    jsets(req, "next_offset", next);
    json_release(tg_post("answerInlineQuery", req, 15));
    0;
}

on_inline(iq) {
    auto uid;
    auto qid;
    auto key;
    auto off;
    auto results;
    auto q;
    auto i;
    auto n;
    auto lim;
    auto chat;
    auto text;

    uid = jint(jget(iq, "from"), "id");
    qid = jstr(iq, "id");
    key = s_lower(s_trim(nz(jstr(iq, "query"), "")));
    off = s_int(jstr(iq, "offset"));
    chat = nz(jstr(iq, "chat_type"), "private");
    results = ja();
    u_load(uid);

    // Список только в личке: в группах и каналах чужие чаты засорять нечем.
    if s_eq(chat, "group") | s_eq(chat, "supergroup") | s_eq(chat, "channel") return inline_answer(qid, results, "");

    if s_eq(u_state, "w_artist") {
        // Служебные пункты — только на первой порции; «моя работа» и «неизвестен» — пока запрос пуст.
        lim = 50;
        if off == 0 {
            if @8 *key == 0 {
                jpush(results, inline_item("s1", sp_own(), "Подпишем тебя как художника", sp_own()));
                jpush(results, inline_item("s2", sp_unk(), "Автор не известен", sp_unk()));
                lim = 47;
            } else lim = 49;
            jpush(results, inline_item("s3", sp_new(), "Предложить художника, которого нет в списке", sp_new()));
        }
        q = qb("SELECT id, name, link FROM artists WHERE strpos(name_key, ");
        sb_lit(q, key);
        sb_add(q, ") > 0 ORDER BY strpos(name_key, ");
        sb_lit(q, key);
        sb_add(q, "), name LIMIT ");
        sb_int(q, lim + 1);
        sb_add(q, " OFFSET ");
        sb_int(q, off);
        if !db_exec(sb_str(q)) return inline_answer(qid, results, "");
        n = db_rows();
        for i = 0 i < n i++ {
            if i < lim {
                text = s_dup(db_val(i, 1));
                jpush(results, inline_item(inline_id("a", db_int(i, 0)), text, db_val(i, 2), text));
            }
        }
        if n > lim return inline_answer(qid, results, s_itoa(off + lim));
        return inline_answer(qid, results, "");
    }

    if s_eq(u_state, "w_chars") {
        lim = 50;
        if off == 0 {
            jpush(results, inline_item("s3", sp_new(), "Предложить братуху, которого нет в списке", sp_new()));
            lim = 49;
        }
        q = qb("SELECT c.id, c.name, c.aliases FROM characters c WHERE strpos(c.search, ");
        sb_lit(q, key);
        sb_add(q, ") > 0 AND NOT EXISTS (SELECT 1 FROM request_chars rc WHERE rc.character_id = c.id AND rc.request_id = ");
        sb_int(q, u_req);
        sb_add(q, ") ORDER BY strpos(c.search, ");
        sb_lit(q, key);
        sb_add(q, "), c.name LIMIT ");
        sb_int(q, lim + 1);
        sb_add(q, " OFFSET ");
        sb_int(q, off);
        if !db_exec(sb_str(q)) return inline_answer(qid, results, "");
        n = db_rows();
        for i = 0 i < n i++ {
            if i < lim {
                text = s_dup(db_val(i, 1));
                jpush(results, inline_item(inline_id("c", db_int(i, 0)), text, db_val(i, 2), text));
            }
        }
        if n > lim return inline_answer(qid, results, s_itoa(off + lim));
        return inline_answer(qid, results, "");
    }

    // Нет активного шага выбора: подсказка.
    jpush(results, inline_item("h1", "Сначала открой меню бота", "Нажми /start → «Предложить работу»", "/start"));
    inline_answer(qid, results, "");
}
