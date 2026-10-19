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
//   художник/братуха: e_name e_extra e_note e_review e_edit
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

// Подпись к фото ограничена 1024 символами.
pic_fits(html) s_u16(html) <= 1024;

// Показывает панель: правит старую на месте или (fresh, либо если правка не
// удалась, либо у старой другой вид — фото вместо текста и наоборот) отправляет новую и
// удаляет старую. pic — имя баннера (панель-фото) или 0 (обычный текст); не помещается
// подпись — панель тоже уходит без баннера. kb — массив рядов кнопок или 0.
panel_pic(uid, pic, html, kb, fresh) {
    auto mk;
    auto id;
    auto ok;
    auto tried;
    auto had;

    if pic {
        if !pic_fits(html) pic = 0;
    }
    mk = 0;
    if kb mk = kb_markup(kb);
    ok = 0;
    tried = 0;
    if (u_panel != 0) & !fresh {
        had = u_pic;
        if s_eq(had, nz(pic, "")) {
            tried = 1;
            if pic ok = tg_edit_caption(uid, u_panel, html, mk);
            else ok = tg_edit(uid, u_panel, html, jcopy(mk));
        } else if (@8 *had != 0) & (pic != 0) {
            tried = 1;
            ok = tg_edit_pic(uid, u_panel, pic, html, mk);
            if ok u_set_panel(uid, u_panel, pic);
        }
        // Текст не изменился — это не ошибка.
        if tried & !ok {
            if tg_err_has("not modified") ok = 1;
        }
    }
    if ok {
        json_release(mk);
        return 1;
    }
    if u_panel != 0 tg_delete(uid, u_panel);
    id = 0;
    if pic id = tg_photo(uid, pic, html, mk);
    if !id {
        pic = 0;  // нет файла баннера или Telegram его не принял: панель текстом
        id = tg_send(uid, html, mk);
        mk = 0;
    }
    json_release(mk);
    if id u_set_panel(uid, id, nz(pic, ""));
    id != 0;
}

panel(uid, html, kb, fresh) panel_pic(uid, 0, html, kb, fresh);

// Отдельное сообщение с баннером (уведомление): без баннера уходит обычным текстом.
send_pic(chat, pic, html) {
    auto id;
    id = 0;
    if pic_fits(html) id = tg_photo(chat, pic, html, 0);
    if !id id = tg_send(chat, html, 0);
    id;
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
    kb_row2(kb, btn_cb("🎨 Предложить художника", "m:artist"), btn_cb("👤 Предложить братуху", "m:hero"));
    kb_row2(kb, btn_cb("📋 Мои заявки", "m:mine"), btn_cb("ℹ️ Правила", "m:rules"));
    panel_pic(uid, "menu", "Здарова, братуха! 👋\n\nЭто предложка канала <b>42 CONFESSION</b>. Присылай арты и творчество про 42 братух — админ проверит, и бот выложит всё в канал.\n\nЧто делаем?", kb, fresh);
}

show_rules(uid) {
    auto kb;
    kb = ja();
    kb_row1(kb, btn_cb("⬅️ В меню", "m:home"));
    panel_pic(uid, "rules", "ℹ️ <b>Правила</b>\n\n• Можно предлагать свои и чужие работы про 42 братух: картинки, видео, GIF, файлы или текст.\n• Художника и братух выбираешь из списка. Нет в списке — предложи нового, админ добавит.\n• Каждую заявку проверяет админ: примет, поправит или отклонит.\n• В канале можно остаться анонимом или подписаться.", kb, 0);
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
                sb_add(b, " 👤 Братуха «");
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
                    // Полную причину пользователь уже получил уведомлением; здесь коротко,
                    // чтобы список поместился в подпись к баннеру.
                    sb_add(b, ": ");
                    sb_html(b, s_cutc(db_val(i, 3), 50), 0);
                }
            }
        }
    }
    kb = ja();
    kb_row1(kb, btn_cb("⬅️ В меню", "m:home"));
    panel_pic(uid, "mine", sb_str(b), kb, 0);
}
