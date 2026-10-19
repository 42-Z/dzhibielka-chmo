// admin.k: проверка заявок админами.
//
// Карточка заявки приходит каждому админу в личку и после решения правится у всех.
// Решения (опубликовать, добавить, отклонить) выполняются UPDATE ... WHERE
// status = 'pending': повторное нажатие или решение другого админа ничего не меняет.

// --- карточка ------------------------------------------------------------------

// Имя админа, принявшего решение по заявке, или пустая строка.
decider_name(rid) {
    auto q;
    q = qb("SELECT u.first_name FROM requests r JOIN users u ON u.id = r.decided_by WHERE r.id = ");
    sb_int(q, rid);
    if !db_exec(sb_str(q)) return "";
    if db_rows() < 1 return "";
    s_dup(db_val(0, 0));
}

// Текст карточки по загруженной заявке (r_*).
card_text() {
    auto b;
    b = sb_new();
    sb_add(b, "📨 <b>Заявка #");
    sb_int(b, r_id);
    if s_eq(r_kind, "work") sb_add(b, " — работа</b>\n");
    else if s_eq(r_kind, "artist") sb_add(b, " — новый художник</b>\n");
    else sb_add(b, " — новый герой</b>\n");
    sb_add(b, "От: <a href=\"tg://user?id=");
    sb_int(b, r_user);
    sb_add(b, "\">");
    sb_html(b, r_ufirst, 0);
    sb_add(b, "</a>");
    if @8 *r_uname != 0 {
        sb_add(b, " @");
        sb_html(b, r_uname, 0);
    }
    sb_add(b, "\n\n");
    if s_eq(r_kind, "work") {
        sb_add(b, post_html(post_limit()));
        if (r_artist == 0) & (@8 *r_nart != 0) {
            sb_add(b, "\n\n🆕 Новый художник: <b>");
            sb_html(b, r_nart, 0);
            sb_add(b, "</b>");
            if s_eq(r_mode, "own") sb_add(b, " (сам автор)");
        }
        if @8 *r_nchars != 0 {
            sb_add(b, "\n🆕 Новые герои: <b>");
            sb_html(b, l_join(r_nchars), 0);
            sb_add(b, "</b>");
        }
    } else ent_summary(b);
    if s_eq(r_status, "approved") {
        if s_eq(r_kind, "work") sb_add(b, "\n\n✅ Опубликовано");
        else sb_add(b, "\n\n✅ Добавлено");
        sb_add(b, " — ");
        sb_html(b, decider_name(r_id), 0);
    } else if s_eq(r_status, "rejected") {
        sb_add(b, "\n\n❌ Отклонено — ");
        sb_html(b, decider_name(r_id), 0);
        if @8 *r_reason != 0 {
            sb_add(b, "\nПричина: ");
            sb_html(b, r_reason, 0);
        }
    }
    sb_str(b);
}

card_kb(rid) {
    auto kb;
    kb = ja();
    if s_eq(r_status, "pending") {
        if s_eq(r_kind, "work") kb_row1(kb, btn_cb("✅ Опубликовать", cba("ok", rid)));
        else kb_row1(kb, btn_cb("✅ Добавить", cba("ok", rid)));
        kb_row2(kb, btn_cb("✏️ Исправить", cba("fix", rid)), btn_cb("❌ Отклонить", cba("no", rid)));
    }
    kb;
}

// Отправляет карточку заявки одному админу и запоминает её сообщение. Для работы
// сначала отправляется само содержимое, чтобы админ увидел его в чате. Истина,
// если карточка дошла (админ мог ни разу не написать боту — тогда Telegram откажет).
card_to(rid, admin) {
    auto text;
    auto preview;
    auto mid;
    auto q;

    if !rq_load(rid) return 0;
    text = card_text();
    // Текст работы уже есть в самой карточке, поэтому отдельный показ нужен только медиа.
    preview = s_eq(r_kind, "work") & !r_istext();
    if preview send_work(s_itoa(admin), post_html(post_limit()));
    mid = tg_send(admin, text, kb_markup(card_kb(rid)));
    if !mid return 0;
    q = qb("INSERT INTO cards (request_id, admin_id, message_id) VALUES (");
    sb_int(q, rid);
    sb_add(q, ", ");
    sb_int(q, admin);
    sb_add(q, ", ");
    sb_int(q, mid);
    sb_add(q, ") ON CONFLICT (request_id, admin_id) DO UPDATE SET message_id = EXCLUDED.message_id");
    db_exec(sb_str(q));
    1;
}

// Рассылает карточку заявки всем админам. Не дошла ни до одного — пишет в журнал;
// такие заявки админ получит позже командой /start (cards_backlog).
cards_send(rid) {
    auto i;
    auto sent;
    sent = 0;
    for i = 0 i < cfg_admin_n i++ {
        if card_to(rid, cfg_admin[i]) sent++;
    }
    if !sent fprintf(stderr, "Заявка #%lld: карточка не дошла ни до одного админа\n", rid);
    sent;
}

// Досылает админу карточки ожидающих заявок, которых у него ещё нет (не писал боту
// раньше, сбой доставки): не больше двадцати за раз.
cards_backlog(admin) {
    auto q;
    auto ids;
    auto n;
    auto i;
    q = qb("SELECT r.id FROM requests r WHERE r.status = 'pending' AND NOT EXISTS ");
    sb_add(q, "(SELECT 1 FROM cards c WHERE c.request_id = r.id AND c.admin_id = ");
    sb_int(q, admin);
    sb_add(q, ") ORDER BY r.id LIMIT 20");
    if !db_exec(sb_str(q)) return 0;
    n = db_rows();
    ids = alloc(160);
    for i = 0 i < n i++ ids[i] = db_int(i, 0);
    for i = 0 i < n i++ card_to(ids[i], admin);
    n;
}

// Перерисовывает карточки заявки у всех админов (после правки или решения).
cards_refresh(rid) {
    auto text;
    auto q;
    auto i;
    auto n;
    auto admins;
    auto mids;

    if !rq_load(rid) return 0;
    admins = alloc(128);
    mids = alloc(128);
    text = card_text();
    q = qb("SELECT admin_id, message_id FROM cards WHERE request_id = ");
    sb_int(q, rid);
    if !db_exec(sb_str(q)) return 0;
    n = db_rows();
    if n > 16 n = 16;
    for i = 0 i < n i++ {
        admins[i] = db_int(i, 0);
        mids[i] = db_int(i, 1);
    }
    for i = 0 i < n i++ {
        tg_edit(admins[i], mids[i], text, kb_markup(card_kb(rid)));
    }
    1;
}

// --- уведомление отправителя ---------------------------------------------------

notify_user(rid) {
    auto b;
    if !rq_load(rid) return 0;
    b = sb_new();
    if s_eq(r_status, "approved") {
        if s_eq(r_kind, "work") {
            sb_add(b, "✅ Твоя работа (заявка #");
            sb_int(b, r_id);
            sb_add(b, ") опубликована!");
            if @8 *r_link != 0 {
                sb_add(b, " <a href=\"");
                sb_html(b, r_link, 1);
                sb_add(b, "\">Открыть пост</a>");
            }
        } else {
            sb_add(b, "✅ «");
            sb_html(b, r_ename, 0);
            sb_add(b, "» добавлен в список — теперь можно выбирать при отправке работ.");
        }
    } else {
        sb_add(b, "❌ Заявка #");
        sb_int(b, r_id);
        sb_add(b, " отклонена.");
        if @8 *r_reason != 0 {
            sb_add(b, "\nПричина: ");
            sb_html(b, r_reason, 0);
        }
    }
    tg_send(r_user, sb_str(b), 0);
}

// --- решения -------------------------------------------------------------------

// Занимает заявку под решение: истина, если она ещё была в ожидании.
claim(rid, admin, status) {
    auto q;
    q = qb("UPDATE requests SET status = ");
    sb_lit(q, status);
    sb_add(q, ", decided_by = ");
    sb_int(q, admin);
    sb_add(q, ", decided_at = now() WHERE status = 'pending' AND id = ");
    sb_int(q, rid);
    if !db_exec(sb_str(q)) return 0;
    db_changed() == 1;
}

// Добавляет в справочник художника/героя из заявки; в работе — все предложенные
// записи. Всё в открытой транзакции. Истина, если получилось.
resolve_new(rid) {
    auto i;
    auto n;
    auto id;
    auto names;

    if !rq_load(rid) return 0;
    if s_eq(r_kind, "artist") {
        id = artist_add(r_ename, r_eextra, 0);
        return id != 0;
    }
    if s_eq(r_kind, "character") {
        id = char_add(r_ename, r_eextra);
        return id != 0;
    }
    if (r_artist == 0) & (@8 *r_nart != 0) {
        if s_eq(r_mode, "own") id = artist_add(r_nart, r_nlink, r_user);
        else id = artist_add(r_nart, r_nlink, 0);
        if !id return 0;
        rq_set_i(rid, "artist_id", id);
        rq_set_s(rid, "artist_mode", "list");
        rq_set_s(rid, "new_artist", "");
        rq_set_s(rid, "new_artist_link", "");
    }
    names = r_nchars;
    n = l_count(names);
    for i = 0 i < n i++ {
        id = char_add(l_get(names, i), "");
        if !id return 0;
        rq_char_add(rid, id);
    }
    rq_set_s(rid, "new_chars", "");
    1;
}

// Объясняет админу, почему не вышла публикация в канал: голое «Bad Request: chat not
// found» не говорит, что бота просто нет в канале.
publish_error(desc) {
    if !desc return "Не получилось опубликовать: неизвестная ошибка";
    if s_has(desc, "chat not found") | s_has(desc, "not a member") | s_has(desc, "was kicked") {
        return "Бота нет в канале (или в CHANNEL_ID указан не тот id). Добавьте бота в канал администратором с правом публикации и нажмите «Опубликовать» ещё раз.";
    }
    if s_has(desc, "rights") | s_has(desc, "CHAT_ADMIN_REQUIRED") | s_has(desc, "CHAT_WRITE_FORBIDDEN") {
        return "У бота нет права публиковать в канале. Включите ему в правах администратора «Публикация сообщений» и нажмите «Опубликовать» ещё раз.";
    }
    sb_str(sb_add(qb("Не получилось опубликовать: "), desc));
}

// Публикует работу. Возвращает текст ошибки или 0.
approve_work(admin, rid) {
    auto mid;
    auto q;
    auto err;

    if !db_begin() return "Нет связи с БД";
    if !claim(rid, admin, "approved") {
        db_rollback();
        return "Заявка уже решена";
    }
    if !resolve_new(rid) {
        db_rollback();
        return "Не получилось добавить новых художников или героев";
    }
    if !rq_load(rid) {
        db_rollback();
        return "Заявка не найдена";
    }
    mid = send_work(cfg_channel, post_html(post_limit()));
    if !mid {
        err = s_cutc(publish_error(tg_last_err), 190);  // в окне Telegram до 200 символов
        db_rollback();
        return err;
    }
    q = qb("UPDATE requests SET channel_link = ");
    sb_lit(q, post_link(mid));
    sb_add(q, " WHERE id = ");
    sb_int(q, rid);
    db_exec(sb_str(q));
    if !db_commit() fprintf(stderr, "Пост опубликован (сообщение %lld), но запись в БД не сохранилась\n", mid);
    0;
}

// Добавляет художника/героя из заявки. Истина, если добавлено (auto — решение без
// карточки, например заявка самого админа).
ent_approve(rid, admin) {
    auto ok;
    if !db_begin() return 0;
    if !claim(rid, admin, "approved") {
        db_rollback();
        return 0;
    }
    ok = resolve_new(rid);
    if !ok {
        db_rollback();
        return 0;
    }
    db_commit();
    rq_load(rid);
    if r_user != admin notify_user(rid);
    cards_refresh(rid);
    1;
}

reject(admin, rid, reason) {
    auto q;
    q = qb("UPDATE requests SET status = 'rejected', reason = ");
    sb_lit(q, reason);
    sb_add(q, ", decided_by = ");
    sb_int(q, admin);
    sb_add(q, ", decided_at = now() WHERE status = 'pending' AND id = ");
    sb_int(q, rid);
    if !db_exec(sb_str(q)) return 0;
    if db_changed() != 1 return 0;
    notify_user(rid);
    cards_refresh(rid);
    1;
}

// Админ написал причину отказа текстом.
admin_reason(uid, text) {
    auto rid;
    rid = u_req;
    u_set(uid, "", 0, "");
    if u_panel tg_delete(uid, u_panel);
    u_set_panel(uid, 0);
    if reject(uid, rid, s_trim(s_cutc(text, 300))) reply(uid, "Отклонено, отправитель получит уведомление.");
    else reply(uid, "Эту заявку уже решили.");
}

// «Готово» в меню правки: сохранить и обновить карточки.
admin_fix_done(uid, rid) {
    u_set(uid, "", 0, "");
    cards_refresh(rid);
    panel(uid, sb_str(sb_add(sb_int(qb("✔ Правки заявки #"), rid), " сохранены.")), 0, 0);
    u_set_panel(uid, 0);
    0;
}

// Кнопки админа: a:<действие>:<заявка>.
on_admin(uid, cbid, data) {
    auto act;
    auto rid;
    auto err;
    auto kb;

    if !is_admin(uid) return tg_ack(cbid, "Это кнопка для админов");
    act = s_field(data, 0, ':');
    rid = s_int(s_field(data, 1, ':'));
    err = 0;

    // Выход из ожидания причины работает всегда, даже если заявку тем временем
    // решил другой админ: иначе панель и шаг «a_reason» остались бы висеть.
    if s_eq(act, "norej") | s_eq(act, "noreason") {
        if s_eq(u_state, "a_reason") & (u_req == rid) {
            if u_panel tg_delete(uid, u_panel);
            u_set_panel(uid, 0);
            u_set(uid, "", 0, "");
        }
        if s_eq(act, "norej") return tg_ack(cbid, 0);
        if !reject(uid, rid, "") return tg_ack(cbid, "Эту заявку уже решили");
        return tg_ack(cbid, 0);
    }

    if !rq_load(rid) return tg_ack(cbid, "Заявка не найдена");
    if !s_eq(r_status, "pending") {
        cards_refresh(rid);
        return tg_ack(cbid, "Эту заявку уже решили");
    }
    // Отклонение и правка занимают шаг диалога админа: не затираем его незаконченную заявку.
    if s_eq(act, "no") | s_eq(act, "fix") {
        if (@8 *u_state != 0) & (u_req != rid) return tg_ack(cbid, "Сначала закончи текущую заявку или нажми /cancel");
    }

    if s_eq(act, "ok") {
        if s_eq(r_kind, "work") err = approve_work(uid, rid);
        else if !ent_approve(rid, uid) err = "Заявка уже решена или имя не получилось добавить";
        if !err {
            if s_eq(r_kind, "work") {
                notify_user(rid);
                cards_refresh(rid);
            }
        }
    } else if s_eq(act, "no") {
        u_set(uid, "a_reason", rid, "");
        kb = ja();
        kb_row2(kb, btn_cb("Без причины", cba("noreason", rid)), btn_cb("Отмена", cba("norej", rid)));
        panel(uid, sb_str(sb_add(sb_int(qb("❌ Напиши причину отказа для заявки #"), rid), " — её увидит отправитель.")), kb, 1);
    } else if s_eq(act, "fix") {
        u_set(uid, "a_fix", rid, "");
        show_step(uid, 1);
    } else err = "Неизвестная кнопка";
    if err return tg_alert(cbid, err);
    tg_ack(cbid, 0);
}
