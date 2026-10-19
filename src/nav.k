// nav.k: навигационный пост в канале — список всех хэштегов художников и братух.
//
// Пост создаёт только админ кнопкой «📍 Навигация» в Меню (nav_sync с make=1). Дальше он
// обновляется сам: одобрение художника или братухи ставит nav_dirty, а main вызывает
// nav_flush после каждого update. Список длинный, поэтому пост хранится частями (лимит
// Telegram 4096 символов). Номер части, id сообщения и текст последней отправки лежат в
// nav_posts; совпадающую часть Telegram не трогает.
//
// Если сообщение удалили в канале вручную, при обновлении по кнопке оно отправляется заново.
// Автообновление (nav_flush) сообщений не заводит: без поста оно ничего не делает.

nav_dirty;          // справочник менялся: пост надо пересобрать (см. nav_flush)
nav_cur;            // строитель текущей части поста
nav_curv;           // её видимая длина в единицах UTF-16
nav_seen;           // уже выведенные теги: «\n<тег>\n» на каждый
nav_n;              // сколько частей собрано
nav_over;           // частей больше, чем помещается в nav_part
nav_part[64];       // тексты собранных частей (HTML)
nav_mid_of[64];     // id сообщения в канале для части номер i (0 — такой части нет)
nav_body_of[64];    // текст части при последней отправке (из nav_posts)

// Закрывает текущую часть и переходит к следующей.
nav_close() {
    if nav_n >= 64 {
        nav_over = 1;
        return 0;
    }
    nav_part[nav_n] = sb_str(nav_cur);
    nav_n++;
    nav_cur = sb_new();
    nav_curv = 0;
    1;
}

// Дописывает строку html (HTML) в текущую часть; не помещается — часть закрывается.
// Лимит 3800 — с запасом до 4096 символов Telegram.
nav_line(html) {
    auto v;
    if nav_over return 0;
    v = s_u16(html);
    if (nav_curv > 0) & (nav_curv + 1 + v > 3800) nav_close();
    if nav_curv {
        sb_c(nav_cur, '\n');
        nav_curv++;
    }
    sb_add(nav_cur, html);
    nav_curv = nav_curv + v;
    1;
}

// Истина, если тег уже выведен в пост.
nav_seen_has(tag) {
    auto b;
    b = sb_new();
    sb_c(b, '\n');
    sb_add(b, tag);
    sb_c(b, '\n');
    s_has(sb_str(nav_seen), sb_str(b));
}

nav_seen_add(tag) {
    sb_add(nav_seen, tag);
    sb_c(nav_seen, '\n');
    0;
}

// Выводит теги одной выборки «name, tag»: строки по десять тегов, без повторов. Пустой
// тег берётся из имени. Истина, если запрос прошёл.
nav_section(title, sql) {
    auto i;
    auto n;
    auto name;
    auto tag;
    auto lb;
    auto k;

    nav_line(title);
    if !db_exec(sql) return 0;
    n = db_rows();
    lb = sb_new();
    k = 0;
    // строки из db_val копируем сразу: следующий запрос их освободит
    for i = 0 i < n i++ {
        name = s_dup(db_val(i, 0));
        tag = s_dup(db_val(i, 1));
        if @8 *tag == 0 tag = s_tag(name);
        if (@8 *tag != 0) & !nav_seen_has(tag) {
            nav_seen_add(tag);
            if k sb_c(lb, ' ');
            sb_c(lb, '#');
            sb_add(lb, tag);
            k++;
            if k == 10 {
                nav_line(sb_str(lb));
                lb = sb_new();
                k = 0;
            }
        }
    }
    if k nav_line(sb_str(lb));
    1;
}

// Собирает части поста из справочника: художники, затем братухи. Истина, если получилось.
nav_build() {
    auto q;

    nav_cur = sb_new();
    nav_curv = 0;
    nav_seen = sb_new();
    sb_c(nav_seen, '\n');
    nav_n = 0;
    nav_over = 0;

    nav_line("📍 <b>Навигация по хэштегам</b>");
    nav_line("");
    q = qb("SELECT name, tag FROM artists ORDER BY name_key");
    if !nav_section("🎨 <b>Художники</b>", sb_str(q)) return 0;
    nav_line("");
    q = qb("SELECT name, tag FROM characters ORDER BY name_key");
    if !nav_section("👥 <b>Братухи</b>", sb_str(q)) return 0;
    if nav_curv nav_close();
    if nav_over return 0;
    1;
}

// Читает части поста из nav_posts в nav_mid_of и nav_body_of (индекс — номер части).
// Истина, если запрос прошёл.
nav_load() {
    auto q;
    auto i;
    auto n;
    auto p;

    for i = 0 i < 64 i++ {
        nav_mid_of[i] = 0;
        nav_body_of[i] = "";
    }
    q = qb("SELECT part, message_id, body FROM nav_posts WHERE chat = ");
    sb_lit(q, cfg_channel);
    if !db_exec(sb_str(q)) return 0;
    n = db_rows();
    for i = 0 i < n i++ {
        p = db_int(i, 0);
        if p < 64 {
            nav_mid_of[p] = db_int(i, 1);
            nav_body_of[p] = s_dup(db_val(i, 2));
        }
    }
    1;
}

// Запоминает часть: id сообщения и текст. Возвращает текст ошибки или 0.
nav_save(i, mid, body) {
    auto q;
    q = qb("INSERT INTO nav_posts (part, chat, message_id, body) VALUES (");
    sb_int(q, i);
    sb_add(q, ", ");
    sb_lit(q, cfg_channel);
    sb_add(q, ", ");
    sb_int(q, mid);
    sb_add(q, ", ");
    sb_lit(q, body);
    sb_add(q, ") ON CONFLICT (part) DO UPDATE SET chat = EXCLUDED.chat, message_id = EXCLUDED.message_id, body = EXCLUDED.body");
    if !db_exec(sb_str(q)) return "Нет связи с БД";
    nav_mid_of[i] = mid;
    nav_body_of[i] = body;
    0;
}

// Текст для админа, если Telegram не принял пост.
nav_error() {
    if !tg_last_err return "Не получилось обновить пост в канале";
    if tg_err_has("chat not found") | tg_err_has("not a member") | tg_err_has("was kicked") {
        return "Бота нет в канале (или в CHANNEL_ID указан не тот id). Добавьте бота в канал администратором с правом публикации.";
    }
    if tg_err_has("rights") | tg_err_has("CHAT_ADMIN_REQUIRED") | tg_err_has("CHAT_WRITE_FORBIDDEN") {
        return "У бота нет права публиковать в канале. Включите ему в правах администратора «Публикация сообщений».";
    }
    sb_str(sb_add(qb("Не получилось обновить пост в канале: "), tg_last_err));
}

// Приводит часть i к тексту справочника: правит сообщение или, если его удалили в канале,
// отправляет заново. force — правка по кнопке: тогда сообщение проверяется, даже если текст
// не менялся. Возвращает текст ошибки или 0.
nav_part_sync(i, force) {
    auto mid;
    auto body;

    mid = nav_mid_of[i];
    body = nav_part[i];
    if mid {
        if (force == 0) & s_eq(nav_body_of[i], body) return 0;
        // «not modified» значит, что сообщение на месте и текст уже такой
        if (tg_chan_edit(mid, body) | tg_err_has("not modified")) return nav_save(i, mid, body);
        if !tg_err_has("to edit not found") return nav_error();
    }
    mid = tg_chan_send(body);
    if !mid return nav_error();
    nav_save(i, mid, body);
}

// Приводит пост в канале к справочнику. Без make поста не создаёт: если его нет, ничего не
// делает. Возвращает текст ошибки для админа или 0.
nav_sync(make) {
    auto q;
    auto i;
    auto err;

    // записи о прежнем канале (CHANNEL_ID сменили) к посту не относятся
    q = qb("DELETE FROM nav_posts WHERE chat <> ");
    sb_lit(q, cfg_channel);
    if !db_exec(sb_str(q)) return "Нет связи с БД";
    if !nav_load() return "Нет связи с БД";
    if (make == 0) & (nav_mid_of[0] == 0) return 0;
    if !nav_build() return "Не получилось собрать список хэштегов из базы";
    for i = 0 i < nav_n i++ {
        err = nav_part_sync(i, make);
        if err return err;
    }
    // части, которых теперь нет, убираем из канала и из таблицы
    for i = nav_n i < 64 i++ {
        if nav_mid_of[i] tg_chan_delete(nav_mid_of[i]);
    }
    q = qb("DELETE FROM nav_posts WHERE chat = ");
    sb_lit(q, cfg_channel);
    sb_add(q, " AND part >= ");
    sb_int(q, nav_n);
    if !db_exec(sb_str(q)) return "Нет связи с БД";
    0;
}

// Пересобирает пост после изменения справочника. Вызывается после каждого update, но
// Telegram трогает пост, только если текст реально поменялся. Ошибка уходит в журнал: решение
// админа уже сохранено, а кнопка «Обновить» в экране навигации повторит попытку.
nav_flush() {
    auto err;
    if !nav_dirty return 0;
    nav_dirty = 0;
    err = nav_sync(0);
    if err fprintf(stderr, "Навигационный пост не обновился: %s\n", err);
    0;
}

// Удаляет навигационный пост из канала и из таблицы. Если Telegram не дал удалить, таблица
// не трогается, чтобы пост не остался в канале без записи.
nav_remove() {
    auto q;
    auto i;

    if !nav_load() return "Нет связи с БД";
    for i = 0 i < 64 i++ {
        if nav_mid_of[i] {
            if !tg_chan_delete(nav_mid_of[i]) {
                if !tg_err_has("to delete not found") return nav_error();
            }
        }
    }
    q = qb("DELETE FROM nav_posts WHERE chat = ");
    sb_lit(q, cfg_channel);
    if !db_exec(sb_str(q)) return "Нет связи с БД";
    0;
}

// Экран навигационного поста: статус, ссылка и кнопки.
show_nav(uid) {
    auto b;
    auto kb;
    auto link;

    kb = ja();
    b = sb_new();
    sb_add(b, "📍 <b>Навигационный пост</b>\n\n");
    if !nav_load() {
        sb_add(b, "Не получилось прочитать данные из базы.");
    } else if nav_mid_of[0] {
        sb_add(b, "Пост со всеми хэштегами стоит в канале. Он обновляется сам, когда одобряют художника или братуху.");
        link = post_link(nav_mid_of[0]);
        if @8 *link != 0 {
            sb_add(b, "\n\n<a href=\"");
            sb_html(b, link, 1);
            sb_add(b, "\">Открыть пост</a>");
        }
        kb_row2(kb, btn_cb("🔄 Обновить", "n:refresh"), btn_cb("🗑 Удалить", "n:del"));
    } else {
        sb_add(b, "Поста в канале нет. Создай его — дальше он будет обновляться сам.");
        kb_row1(kb, btn_cb("➕ Создать пост", "n:make"));
    }
    kb_row1(kb, btn_cb("⬅️ В меню", "m:home"));
    panel_pic(uid, "menu", sb_str(b), kb, 0);
}

// Кнопки навигационного поста: n:<действие>. Только для админов.
on_nav(uid, cbid, act) {
    auto err;

    if !is_admin(uid) return tg_ack(cbid, "Это кнопка для админов");
    if s_eq(act, "show") {
        show_nav(uid);
        return tg_ack(cbid, 0);
    }
    if s_eq(act, "make") | s_eq(act, "refresh") {
        err = nav_sync(1);
    } else if s_eq(act, "del") {
        err = nav_remove();
    } else return tg_ack(cbid, "Неизвестная кнопка");
    if err return tg_alert(cbid, s_cutc(err, 190));  // в окне Telegram до 200 символов
    show_nav(uid);
    tg_ack(cbid, 0);
}
