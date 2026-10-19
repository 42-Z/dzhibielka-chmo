// user.k: сообщения и кнопки пользователя — меню, мастер заявки, выбор из списка.
//
// Один и тот же мастер служит и отправителю, и админу, который правит чужую
// заявку (см. wizard.k). Ошибки пользователю возвращаются строкой: её показывает
// tg_ack всплывающим уведомлением.

mt_type;   // тип вложения последнего msg_media: photo, video, animation, document
mt_file;   // его file_id

// Служебные пункты выпадающего списка; тот же текст приходит назад сообщением via_bot.
sp_own() "🙋 Это моя работа";
sp_unk() "❔ Автор неизвестен";
sp_new() "➕ Нет в списке";

reply(uid, html) tg_send(uid, html, 0);

// Истина, если text — команда cmd (например "/start"): после имени идёт конец
// строки, пробел или @имя_бота.
is_cmd(text, cmd) {
    auto n;
    auto c;
    if !s_starts(text, cmd) return 0;
    c = @8 *(text + strlen(cmd));
    (c == 0) | (c == ' ') | (c == '\n') | (c == '@');
}

// --- переходы между шагами -----------------------------------------------------

// Шаг после текущего (нужна загруженная заявка: у текстовой работы нет подписи).
st_next() {
    if s_eq(u_state, "w_media") return "w_artist";
    if s_eq(u_state, "w_artist") return "w_chars";
    if s_eq(u_state, "w_aname") return "w_alink";
    if s_eq(u_state, "w_alink") return "w_chars";
    if s_eq(u_state, "w_cnew") return "w_chars";
    if s_eq(u_state, "w_chars") {
        if r_istext() return "w_credit";
        return "w_caption";
    }
    if s_eq(u_state, "w_caption") return "w_credit";
    if s_eq(u_state, "w_credit") return "w_review";
    if s_eq(u_state, "e_name") return "e_extra";
    if s_eq(u_state, "e_extra") return "e_note";
    if s_eq(u_state, "e_note") return "e_review";
    "";
}

st_prev() {
    if s_eq(u_state, "w_artist") return "w_media";
    if s_eq(u_state, "w_chars") return "w_artist";
    if s_eq(u_state, "w_aname") return "w_artist";
    if s_eq(u_state, "w_alink") return "w_aname";
    if s_eq(u_state, "w_cnew") return "w_chars";
    if s_eq(u_state, "w_caption") return "w_chars";
    if s_eq(u_state, "w_credit") {
        if r_istext() return "w_chars";
        return "w_caption";
    }
    if s_eq(u_state, "e_extra") return "e_name";
    if s_eq(u_state, "e_note") return "e_extra";
    "";
}

// Шаг закончен: вернуться туда, откуда пришли править, либо идти дальше.
leave(uid, fresh) {
    auto to;
    to = u_ret;
    if @8 *to == 0 to = st_next();
    u_set(uid, to, u_req, "");
    show_step(uid, fresh);
}

// Удаляет черновик и возвращает пользователя в меню.
cancel_draft(uid, rid, fresh) {
    auto q;
    if rid {
        q = qb("DELETE FROM requests WHERE status = 'draft' AND id = ");
        sb_int(q, rid);
        sb_add(q, " AND user_id = ");
        sb_int(q, uid);
        db_exec(sb_str(q));
    }
    u_set(uid, "", 0, "");
    show_menu(uid, fresh);
}

back_step(uid) {
    auto to;
    // Подшаги художника и героев возвращают на предыдущий экран, а не из правки.
    if (s_eq(u_state, "w_aname") | s_eq(u_state, "w_alink") | s_eq(u_state, "w_cnew")) {
        u_set(uid, st_prev(), u_req, u_ret);
        return show_step(uid, 0);
    }
    if @8 *u_ret != 0 {
        u_set(uid, u_ret, u_req, "");
        return show_step(uid, 0);
    }
    if s_eq(u_state, "w_edit") {
        u_set(uid, "w_review", u_req, "");
        return show_step(uid, 0);
    }
    if s_eq(u_state, "e_edit") {
        u_set(uid, "e_review", u_req, "");
        return show_step(uid, 0);
    }
    to = st_prev();
    if @8 *to == 0 return cancel_draft(uid, u_req, 0);
    u_set(uid, to, u_req, "");
    show_step(uid, 0);
}

// Куда возвращаться после правки шага, открытой из меню текущего экрана.
ret_for_edit() {
    if s_eq(u_state, "a_fix") return "a_fix";
    if s_eq(u_state, "e_edit") return "e_review";
    "w_review";
}

goto_state(step) {
    if s_eq(step, "media") return "w_media";
    if s_eq(step, "artist") return "w_artist";
    if s_eq(step, "chars") return "w_chars";
    if s_eq(step, "caption") return "w_caption";
    if s_eq(step, "credit") return "w_credit";
    if s_eq(step, "ename") return "e_name";
    if s_eq(step, "eextra") return "e_extra";
    if s_eq(step, "enote") return "e_note";
    "";
}

// --- отправка заявки -----------------------------------------------------------

// Черновик -> заявка на проверку. Возвращает текст ошибки или 0.
do_send(uid, rid) {
    auto q;
    auto kb;
    auto auto_ok;

    if s_eq(r_kind, "work") {
        if r_items_n() == 0 return "Сначала пришли работу";
        if !artist_set() return "Выбери художника";
    } else if @8 *r_ename == 0 return "Нужно имя";

    q = qb("UPDATE requests SET status = 'pending' WHERE status = 'draft' AND id = ");
    sb_int(q, rid);
    sb_add(q, " AND user_id = ");
    sb_int(q, uid);
    if !db_exec(sb_str(q)) return "Не получилось отправить, попробуй ещё раз";
    if db_changed() != 1 return "Заявка уже отправлена";
    u_set(uid, "", 0, "");

    auto_ok = 0;
    if !s_eq(r_kind, "work") & is_admin(uid) auto_ok = ent_approve(rid, uid);
    if !auto_ok cards_send(rid);

    kb = ja();
    kb_row1(kb, btn_cb("⬅️ В меню", "m:home"));
    if auto_ok panel(uid, "✅ Готово — добавлено в список без проверки.", kb, 0);
    else panel(uid, "✅ <b>Заявка отправлена</b>\n\nАдмин проверит её, и я сообщу, что решили. Статус можно посмотреть в «Мои заявки».", kb, 0);
    0;
}

// --- кнопки --------------------------------------------------------------------

on_menu(uid, cbid, what) {
    auto rid;
    if s_eq(what, "work") {
        rid = rq_new(uid, "work");
        u_set(uid, "w_media", rid, "");
        show_step(uid, 0);
    } else if s_eq(what, "artist") {
        rid = rq_new(uid, "artist");
        u_set(uid, "e_name", rid, "");
        show_step(uid, 0);
    } else if s_eq(what, "hero") {
        rid = rq_new(uid, "character");
        u_set(uid, "e_name", rid, "");
        show_step(uid, 0);
    } else if s_eq(what, "mine") show_mine(uid);
    else if s_eq(what, "rules") show_rules(uid);
    else {
        // «В меню» бросает незаконченный черновик.
        if u_req cancel_draft(uid, u_req, 0);
        else show_menu(uid, 0);
    }
    tg_ack(cbid, 0);
}

// Кнопки мастера: w:<действие>:<заявка>[:<аргумент>].
on_wizard(uid, cbid, data) {
    auto act;
    auto rid;
    auto arg;
    auto err;
    auto name;
    auto st;

    act = s_field(data, 0, ':');
    rid = s_int(s_field(data, 1, ':'));
    arg = s_field(data, 2, ':');
    err = 0;

    if !rq_load(rid) return tg_ack(cbid, "Заявка не найдена");
    if !(r_user == uid) {
        if !is_admin(uid) | !s_eq(r_status, "pending") return tg_ack(cbid, "Это не твоя заявка");
    } else if !s_eq(r_status, "draft") {
        if !is_admin(uid) | !s_eq(r_status, "pending") return tg_ack(cbid, "Заявка уже отправлена");
    }
    if u_req != rid return tg_ack(cbid, "Эта кнопка устарела — открой меню командой /start");
    st = u_state;
    // Кнопки смены шага несут шаг, на котором их нарисовали (см. cbs в ui.k).
    if s_eq(act, "next") | s_eq(act, "back") | s_eq(act, "skip") | s_eq(act, "capdel") | s_eq(act, "uselink") {
        if !s_eq(arg, st) return tg_ack(cbid, "Эта кнопка устарела");
    }

    if s_eq(act, "next") {
        if s_eq(st, "w_media") & (r_items_n() == 0) err = "Сначала пришли работу";
        else if s_eq(st, "w_artist") & !artist_set() err = "Выбери художника";
        else leave(uid, 0);
    } else if s_eq(act, "back") back_step(uid);
    else if s_eq(act, "cancel") cancel_draft(uid, rid, 0);
    else if s_eq(act, "clear") {
        rq_items_clear(rid);
        show_step(uid, 0);
    } else if s_eq(act, "own") {
        rq_set_i(rid, "artist_id", 0);
        rq_set_s(rid, "new_artist", "");
        rq_set_s(rid, "new_artist_link", "");
        if artist_of_user(r_user) {
            rq_set_i(rid, "artist_id", ent_id);
            rq_set_s(rid, "artist_mode", "list");
            show_step(uid, 0);
        } else {
            rq_set_s(rid, "artist_mode", "own");
            u_set(uid, "w_aname", rid, u_ret);
            show_step(uid, 0);
        }
    } else if s_eq(act, "unk") {
        rq_set_i(rid, "artist_id", 0);
        rq_set_s(rid, "artist_mode", "unknown");
        rq_set_s(rid, "new_artist", "");
        rq_set_s(rid, "new_artist_link", "");
        show_step(uid, 0);
    } else if s_eq(act, "anew") {
        rq_set_i(rid, "artist_id", 0);
        rq_set_s(rid, "artist_mode", "new");
        rq_set_s(rid, "new_artist", "");
        rq_set_s(rid, "new_artist_link", "");
        u_set(uid, "w_aname", rid, u_ret);
        show_step(uid, 0);
    } else if s_eq(act, "useunm") {
        name = r_ufirst;
        if @8 *name == 0 name = r_uname;
        rq_set_s(rid, "new_artist", s_cutc(name, 40));
        u_set(uid, "w_alink", rid, u_ret);
        show_step(uid, 0);
    } else if s_eq(act, "uselink") {
        rq_set_s(rid, "new_artist_link", sb_str(sb_add(qb("https://t.me/"), r_uname)));
        leave(uid, 0);
    } else if s_eq(act, "skip") {
        if s_eq(st, "w_alink") | s_eq(st, "w_caption") | s_eq(st, "e_extra") | s_eq(st, "e_note") leave(uid, 0);
        else err = "Здесь нечего пропускать";
    } else if s_eq(act, "capdel") {
        rq_set_s(rid, "caption", "");
        leave(uid, 0);
    } else if s_eq(act, "credit") {
        rq_set_credit(rid, s_int(arg));
        if s_eq(st, "w_credit") leave(uid, 0);
        else show_step(uid, 0);
    } else if s_eq(act, "chnew") {
        u_set(uid, "w_cnew", rid, u_ret);
        show_step(uid, 0);
    } else if s_eq(act, "chdel") {
        rq_char_del(rid, s_int(arg));
        show_step(uid, 0);
    } else if s_eq(act, "chdelp") {
        rq_set_s(rid, "new_chars", l_del(r_nchars, s_int(arg)));
        show_step(uid, 0);
    } else if s_eq(act, "send") {
        err = do_send(uid, rid);
    } else if s_eq(act, "edit") {
        if s_eq(st, "e_review") u_set(uid, "e_edit", rid, "");
        else u_set(uid, "w_edit", rid, "");
        show_step(uid, 0);
    } else if s_eq(act, "goto") {
        name = goto_state(arg);
        if @8 *name == 0 err = "Неизвестный шаг";
        else {
            u_set(uid, name, rid, ret_for_edit());
            show_step(uid, 0);
        }
    } else if s_eq(act, "fixdone") admin_fix_done(uid, rid);
    else err = "Неизвестная кнопка";
    tg_ack(cbid, err);
}

// --- выбор из списка -----------------------------------------------------------

// Выбор художника или героя: сообщением из выпадающего списка (via_bot) либо
// набранным вручную именем. fresh — показать панель заново внизу чата.
on_pick(uid, text, fresh) {
    auto cnt;
    auto rid;
    text = s_trim(text);
    rid = u_req;
    if !rid return 0;
    if !rq_load(rid) return 0;
    if s_eq(u_state, "w_artist") {
        if s_eq(text, sp_own()) {
            rq_set_i(rid, "artist_id", 0);
            rq_set_s(rid, "new_artist", "");
            rq_set_s(rid, "new_artist_link", "");
            if artist_of_user(r_user) {
                rq_set_i(rid, "artist_id", ent_id);
                rq_set_s(rid, "artist_mode", "list");
            } else {
                rq_set_s(rid, "artist_mode", "own");
                u_set(uid, "w_aname", rid, u_ret);
            }
        } else if s_eq(text, sp_unk()) {
            rq_set_i(rid, "artist_id", 0);
            rq_set_s(rid, "artist_mode", "unknown");
            rq_set_s(rid, "new_artist", "");
            rq_set_s(rid, "new_artist_link", "");
        } else if s_eq(text, sp_new()) {
            rq_set_i(rid, "artist_id", 0);
            rq_set_s(rid, "artist_mode", "new");
            rq_set_s(rid, "new_artist", "");
            rq_set_s(rid, "new_artist_link", "");
            u_set(uid, "w_aname", rid, u_ret);
        } else if artist_find(text) {
            rq_set_i(rid, "artist_id", ent_id);
            rq_set_s(rid, "artist_mode", "list");
            rq_set_s(rid, "new_artist", "");
            rq_set_s(rid, "new_artist_link", "");
        } else {
            reply(uid, "Не нашёл такого художника. Выбери из списка кнопкой «🔎 Выбрать из списка» или нажми «➕ Нет в списке».");
            return 0;
        }
        return show_step(uid, fresh);
    }
    if s_eq(u_state, "w_chars") {
        if s_eq(text, sp_new()) {
            u_set(uid, "w_cnew", rid, u_ret);
            return show_step(uid, fresh);
        }
        if !char_find(text) {
            reply(uid, "Не нашёл такого героя. Выбери из списка кнопкой «🔎 Выбрать из списка» или нажми «➕ Нет в списке».");
            return 0;
        }
        cnt = rq_char_count(rid) + l_count(r_nchars);
        if cnt >= 10 {
            reply(uid, "Больше десяти героев в одном посте не нужно.");
            return 0;
        }
        rq_char_add(rid, ent_id);
        return show_step(uid, fresh);
    }
    0;
}

// --- сообщения -----------------------------------------------------------------

// Вложение сообщения: заполняет mt_type и mt_file. Истина, если вложение поддерживается.
msg_media(msg) {
    auto photo;
    auto n;
    mt_type = 0;
    mt_file = 0;
    photo = jget(msg, "photo");
    n = json_array_size(photo);
    if n > 0 {
        mt_type = "photo";
        mt_file = jstr(json_array_get(photo, n - 1), "file_id");
    } else if jget(msg, "video") {
        mt_type = "video";
        mt_file = jstr(jget(msg, "video"), "file_id");
    } else if jget(msg, "animation") {
        mt_type = "animation";
        mt_file = jstr(jget(msg, "animation"), "file_id");
    } else if jget(msg, "document") {
        mt_type = "document";
        mt_file = jstr(jget(msg, "document"), "file_id");
    }
    mt_file != 0;
}

// Можно ли добавить вложение типа t к уже принятым (первый элемент — first, их n).
// Фото и видео группируются между собой, файлы только с файлами, GIF и текст — по одному.
item_ok(first, n, t) {
    if n == 0 return 1;
    if s_eq(first, "text") return 1;
    if s_eq(first, "animation") | s_eq(t, "animation") return 0;
    if s_eq(first, "document") return s_eq(t, "document");
    !s_eq(t, "document");
}

// Содержимое работы: вложение или текст. fresh — панель заново внизу чата.
in_media(uid, msg) {
    auto text;
    auto cap;
    auto items;
    auto first;
    auto n;
    auto grp;
    auto same;

    if !rq_load(u_req) return 0;
    text = jstr(msg, "text");
    cap = jstr(msg, "caption");
    items = json_loads(r_items, 0, 0);
    n = json_array_size(items);
    first = s_dup(nz(jstr(post_first(items), "t"), ""));
    json_release(items);
    same = 0;

    if msg_media(msg) {
        if !item_ok(first, n, mt_type) {
            reply(uid, "Так смешивать нельзя: фото и видео можно вместе (до 10), файлы — только с файлами, а GIF — по одному. Нажми «Очистить» и пришли заново.");
            return 0;
        }
        if s_eq(first, "text") {
            rq_items_clear(r_id);
            n = 0;
        }
        grp = jstr(msg, "media_group_id");
        if grp {
            same = s_eq(grp, u_group);
            if !same u_set_group(uid, grp);
        } else if @8 *u_group != 0 u_set_group(uid, "");
        if n >= 10 {
            if !same reply(uid, "Достаточно: в одном посте не больше десяти файлов.");
            return 0;
        }
        rq_item_add(r_id, mt_type, mt_file, "");
        if cap {
            if @8 *r_caption == 0 rq_set_s(r_id, "caption", s_trim(s_cutc(cap, 500)));
        }
        // Остальные части альбома приходят отдельными сообщениями: новую панель шлём
        // один раз, а у следующих только обновляем счётчик в ней.
        return show_step(uid, !same);
    }
    if text {
        if s_chars(text) > 3000 {
            reply(uid, "Слишком длинно: в пост помещается до 3000 символов.");
            return 0;
        }
        if (n > 0) & !s_eq(first, "text") {
            // Текст к файлам становится подписью.
            rq_set_s(r_id, "caption", s_trim(s_cutc(text, 500)));
            reply(uid, "Записал как подпись к файлам. Её можно поменять позже.");
            return 0;
        }
        rq_items_clear(r_id);
        rq_item_add(r_id, "text", "", text);
        if @8 *u_group != 0 u_set_group(uid, "");
        return show_step(uid, 1);
    }
    reply(uid, "Этот тип сообщений я пока не принимаю. Пришли картинку, видео, GIF, файл или текст.");
    0;
}

// Сообщение не к месту: заново рисуем текущий экран мастера, а если мастера нет — меню.
// Ждущая причины отказа админская панель остаётся как есть.
reshow(uid) {
    if s_eq(u_state, "a_reason") return 0;
    if (u_req != 0) & (@8 *u_state != 0) {
        if show_step(uid, 1) return 1;
    }
    show_menu(uid, 1);
}

// Текст, набранный на шаге мастера.
in_text(uid, text) {
    auto name;
    auto link;
    auto names;
    auto i;
    auto n;
    auto cnt;
    auto rid;
    auto st;

    rid = u_req;
    st = u_state;
    if rid == 0 return show_menu(uid, 1);
    if !rq_load(rid) return show_menu(uid, 1);

    if s_eq(st, "w_artist") | s_eq(st, "w_chars") return on_pick(uid, text, 1);

    if s_eq(st, "w_aname") {
        name = s_trim(s_cutc(text, 40));
        if @8 *name == 0 return reply(uid, "Напиши имя или ник.");
        if artist_find(name) {
            rq_set_i(rid, "artist_id", ent_id);
            rq_set_s(rid, "artist_mode", "list");
            rq_set_s(rid, "new_artist", "");
            u_set(uid, "w_artist", rid, u_ret);
            reply(uid, "Такой художник уже есть в списке — выбрал его.");
            return show_step(uid, 1);
        }
        rq_set_s(rid, "new_artist", name);
        u_set(uid, "w_alink", rid, u_ret);
        return show_step(uid, 1);
    }
    if s_eq(st, "w_alink") {
        link = link_norm(text);
        if @8 *link == 0 return reply(uid, "Не похоже на ссылку. Пришли адрес страницы или @ник, либо нажми «Пропустить».");
        rq_set_s(rid, "new_artist_link", link);
        return leave(uid, 1);
    }
    if s_eq(st, "w_cnew") {
        names = s_names(text, 5);
        n = l_count(names);
        if n == 0 return reply(uid, "Напиши хотя бы одно имя.");
        cnt = rq_char_count(rid) + l_count(r_nchars);
        for i = 0 i < n i++ {
            name = l_get(names, i);
            if char_find(name) {
                if cnt < 10 {
                    rq_char_add(rid, ent_id);
                    cnt++;
                }
            } else if !l_has(r_nchars, name) & (cnt < 10) {
                r_nchars = l_add(r_nchars, name);
                cnt++;
            }
        }
        rq_set_s(rid, "new_chars", r_nchars);
        u_set(uid, "w_chars", rid, u_ret);
        return show_step(uid, 1);
    }
    if s_eq(st, "w_caption") {
        rq_set_s(rid, "caption", s_trim(s_cutc(text, 500)));
        return leave(uid, 1);
    }
    if s_eq(st, "e_name") {
        name = s_trim(s_cutc(text, 40));
        if @8 *name == 0 return reply(uid, "Напиши имя.");
        if s_eq(r_kind, "artist") {
            if artist_find(name) return reply(uid, "Такой художник уже есть в списке.");
        } else if char_find(name) return reply(uid, "Такой герой уже есть в списке.");
        rq_set_s(rid, "ent_name", name);
        return leave(uid, 1);
    }
    if s_eq(st, "e_extra") {
        if s_eq(r_kind, "artist") {
            link = link_norm(text);
            if @8 *link == 0 return reply(uid, "Не похоже на ссылку. Пришли адрес страницы или @ник, либо нажми «Пропустить».");
            rq_set_s(rid, "ent_extra", link);
        } else rq_set_s(rid, "ent_extra", s_trim(s_cutc(text, 100)));
        return leave(uid, 1);
    }
    if s_eq(st, "e_note") {
        rq_set_s(rid, "note", s_trim(s_cutc(text, 300)));
        return leave(uid, 1);
    }
    if s_eq(st, "a_reason") return admin_reason(uid, text);
    reshow(uid);
}

// Команды: /start, /cancel, /id.
on_command(uid, text) {
    if is_cmd(text, "/id") {
        reply(uid, sb_str(sb_add(sb_int(qb("Твой id: <code>"), uid), "</code>")));
        return 1;
    }
    if is_cmd(text, "/start") | is_cmd(text, "/cancel") | is_cmd(text, "/help") {
        // Незаконченный черновик бросаем.
        if (u_req != 0) & (s_starts(u_state, "w_") | s_starts(u_state, "e_")) cancel_draft(uid, u_req, 1);
        else {
            u_set(uid, "", 0, "");
            show_menu(uid, 1);
        }
        // Админу, который раньше не писал боту или пропустил карточки, досылаем ожидающие заявки.
        if is_cmd(text, "/start") & is_admin(uid) cards_backlog(uid);
        return 1;
    }
    0;
}

on_message(msg) {
    auto from;
    auto uid;
    auto text;
    auto mid;

    if !s_eq(nz(jstr(jget(msg, "chat"), "type"), ""), "private") return 0;
    from = jget(msg, "from");
    uid = jint(from, "id");
    mid = jint(msg, "message_id");
    text = jstr(msg, "text");
    user_touch(from);
    u_load(uid);

    // Сообщение из выпадающего списка: разбираем и сразу убираем из чата.
    if jget(msg, "via_bot") {
        tg_delete(uid, mid);
        if text {
            // Пункт-подсказка списка без шага мастера отправляет «/start».
            if is_cmd(text, "/start") on_command(uid, text);
            else on_pick(uid, text, 1);
        }
        return 0;
    }
    if text {
        if @8 *text == '/' {
            if on_command(uid, text) return 0;
        }
    }
    if s_eq(u_state, "w_media") return in_media(uid, msg);
    if text return in_text(uid, text);
    reshow(uid);
}

// Нажатие кнопки: m: — меню, w: — мастер, a: — решения админа.
on_callback(cb) {
    auto from;
    auto uid;
    auto cbid;
    auto data;

    from = jget(cb, "from");
    uid = jint(from, "id");
    cbid = jstr(cb, "id");
    data = nz(jstr(cb, "data"), "");
    user_touch(from);
    u_load(uid);
    if s_starts(data, "m:") return on_menu(uid, cbid, data + 2);
    if s_starts(data, "w:") return on_wizard(uid, cbid, data + 2);
    if s_starts(data, "a:") return on_admin(uid, cbid, data + 2);
    tg_ack(cbid, 0);
}
