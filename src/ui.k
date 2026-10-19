// ui.k: панель пользователя, меню и экраны пошагового мастера.
//
// У каждого пользователя в чате с ботом одна «панель» — сообщение с кнопками,
// которое правится на месте (panel). Когда пользователь сам отправил сообщение
// (файл, текст), панель отправляется заново внизу чата, а старая удаляется.
//
// Данные кнопок (callback_data, до 64 байт):
//   m:<что>               главное меню (work, artist, hero, mine, rules, home)
//   w:<действие>:<заявка>[:<аргумент>]   шаги мастера заявки
//   a:<действие>:<заявка>                решения админа
//
// Состояния мастера (users.state):
//   работа:   w_media w_artist w_aname w_alink w_chars w_cnew w_caption w_credit w_review w_edit
//   художник/герой: e_name e_extra e_note e_review e_edit
//   админ:    a_fix a_efix a_reason

// --- callback_data -------------------------------------------------------------

cbw(act, rid) {
    auto b;
    b = qb("w:");
    sb_add(b, act);
    sb_c(b, ':');
    sb_int(b, rid);
    sb_str(b);
}

// Кнопки, меняющие шаг, помнят шаг, на котором их нарисовали: повторное нажатие
// (двойной тап, старая панель) тогда не перескакивает через следующий экран.
cbs(act, rid) sb_str(sb_add(sb_c(qb(cbw(act, rid)), ':'), u_state));

cbw2(act, rid, arg) {
    auto b;
    b = qb(cbw(act, rid));
    sb_c(b, ':');
    sb_int(b, arg);
    sb_str(b);
}

cba(act, rid) {
    auto b;
    b = qb("a:");
    sb_add(b, act);
    sb_c(b, ':');
    sb_int(b, rid);
    sb_str(b);
}

// --- панель --------------------------------------------------------------------

// Показывает панель: правит старую на месте или (fresh, либо если правка не
// удалась) отправляет новую и удаляет старую. kb — массив рядов кнопок или 0.
panel(uid, html, kb, fresh) {
    auto mk;
    auto cp;
    auto id;

    mk = 0;
    cp = 0;
    if kb {
        mk = kb_markup(kb);
        cp = jcopy(mk);
    }
    if (u_panel != 0) & !fresh {
        if tg_edit(uid, u_panel, html, mk) {
            json_release(cp);
            return 1;
        }
        // Текст не изменился — это не ошибка.
        if (tg_last_err != 0) & (strstr(tg_last_err, "not modified") != 0) {
            json_release(cp);
            return 1;
        }
    } else json_release(mk);
    if u_panel != 0 tg_delete(uid, u_panel);
    id = tg_send(uid, html, cp);
    if id u_set_panel(uid, id);
    id != 0;
}

next_label() {
    if @8 *u_ret != 0 return "Готово ✔";
    "Дальше ➡️";
}

// Ряд навигации мастера: назад и дальше (дальше — если шаг можно закончить).
nav(kb, rid, can_next) {
    auto row;
    row = jpush(ja(), btn_cb("⬅️ Назад", cbs("back", rid)));
    if can_next jpush(row, btn_cb(next_label(), cbs("next", rid)));
    jpush(kb, row);
}

// Разбор содержимого работы: сколько элементов (r_items_n) и текстовая ли она.
r_items_n() {
    auto items;
    auto n;
    items = json_loads(r_items, 0, 0);
    n = json_array_size(items);
    json_release(items);
    n;
}

r_istext() {
    auto items;
    auto t;
    items = json_loads(r_items, 0, 0);
    t = s_dup(nz(jstr(post_first(items), "t"), ""));
    json_release(items);
    s_eq(t, "text");
}

// --- главное меню и справка ----------------------------------------------------

show_menu(uid, fresh) {
    auto kb;
    kb = ja();
    kb_row1(kb, btn_cb("🖼 Предложить работу", "m:work"));
    kb_row2(kb, btn_cb("🎨 Предложить художника", "m:artist"), btn_cb("👤 Предложить героя", "m:hero"));
    kb_row2(kb, btn_cb("📋 Мои заявки", "m:mine"), btn_cb("ℹ️ Правила", "m:rules"));
    panel(uid, "Здарова, братуха! 👋\n\nЭто предложка канала <b>42 CONFESSION</b>. Присылай арты и творчество про 42 братух — админ проверит, и бот выложит всё в канал.\n\nЧто делаем?", kb, fresh);
}

show_rules(uid) {
    auto kb;
    kb = ja();
    kb_row1(kb, btn_cb("⬅️ В меню", "m:home"));
    panel(uid, "ℹ️ <b>Правила</b>\n\n• Можно предлагать свои и чужие работы про 42 братух: картинки, видео, GIF, файлы или текст.\n• Художника и героев выбираешь из списка. Нет в списке — предложи нового, админ добавит.\n• Каждую заявку проверяет админ: примет, поправит или отклонит.\n• В канале можно остаться анонимом или подписаться.", kb, 0);
}

// «Мои заявки»: последние десять, кроме черновиков.
show_mine(uid) {
    auto q;
    auto b;
    auto kb;
    auto i;
    auto kind;
    auto st;
    b = sb_new();
    q = qb("SELECT id, kind, status, reason, channel_link, ent_name FROM requests WHERE status <> 'draft' AND user_id = ");
    sb_int(q, uid);
    sb_add(q, " ORDER BY id DESC LIMIT 10");
    sb_add(b, "📋 <b>Мои заявки</b>\n");
    if !db_exec(sb_str(q)) sb_add(b, "\nНе получилось загрузить список.");
    else if db_rows() == 0 sb_add(b, "\nПока пусто. Предложи первую работу!");
    else {
        for i = 0 i < db_rows() i++ {
            kind = db_val(i, 1);
            st = db_val(i, 2);
            sb_add(b, "\n#");
            sb_int(b, db_int(i, 0));
            if s_eq(kind, "work") sb_add(b, " 🖼 Работа");
            else if s_eq(kind, "artist") {
                sb_add(b, " 🎨 Художник «");
                sb_html(b, db_val(i, 5), 0);
                sb_add(b, "»");
            } else {
                sb_add(b, " 👤 Герой «");
                sb_html(b, db_val(i, 5), 0);
                sb_add(b, "»");
            }
            if s_eq(st, "pending") sb_add(b, " — ⏳ ждёт проверки");
            else if s_eq(st, "approved") {
                if @8 *db_val(i, 4) != 0 {
                    sb_add(b, " — ✅ <a href=\"");
                    sb_html(b, db_val(i, 4), 1);
                    sb_add(b, "\">опубликовано</a>");
                } else sb_add(b, " — ✅ принято");
            } else {
                sb_add(b, " — ❌ отклонено");
                if @8 *db_val(i, 3) != 0 {
                    sb_add(b, ": ");
                    sb_html(b, db_val(i, 3), 0);
                }
            }
        }
    }
    kb = ja();
    kb_row1(kb, btn_cb("⬅️ В меню", "m:home"));
    panel(uid, sb_str(b), kb, 0);
}
