// wizard.k: экраны мастера заявки на работу и на художника/братуху.
//
// Мастер работает над одной заявкой (u_req) и один и тот же для отправителя и
// для админа, который правит чужую заявку: отличается только «куда вернуться»
// после шага (users.ret). show_step показывает экран по u_state.

// Строка про выбранного художника для текущей заявки (r_*).
artist_now() {
    auto b;
    b = sb_new();
    if r_artist {
        artist_get(r_artist);
        sb_add(b, "<b>");
        sb_html(b, ent_name, 0);
        sb_add(b, "</b>");
    } else if s_eq(r_mode, "unknown") sb_add(b, "<b>неизвестен</b>");
    else if @8 *r_nart != 0 {
        sb_add(b, "🆕 <b>");
        sb_html(b, r_nart, 0);
        sb_add(b, "</b> (ждёт проверки админа)");
    } else sb_add(b, "пока не выбран");
    sb_str(b);
}

// Художник выбран (или признан неизвестным)?
artist_set() (r_artist != 0) | s_eq(r_mode, "unknown") | (@8 *r_nart != 0);

// Подпись кнопки «убрать братуху».
x_label(name) sb_str(sb_add(qb("✖ "), name));

scr_media(uid, fresh) {
    auto b;
    auto kb;
    auto n;
    b = sb_new();
    kb = ja();
    n = r_items_n();
    sb_add(b, "🖼 <b>Новая работа</b>\n\n");
    if n == 0 {
        sb_add(b, "Пришли то, что хочешь предложить: картинку, видео, GIF, файл или просто текст. Можно сразу несколько фото или видео (до 10) — альбомом.");
    } else {
        if r_istext() sb_add(b, "Текст принят.");
        else {
            sb_add(b, "Принято: <b>");
            sb_int(b, n);
            sb_add(b, "</b> шт.");
        }
        sb_add(b, " Пришли ещё или жми «Дальше».");
        kb_row2(kb, btn_cb("Дальше ➡️", cbs("next", r_id)), btn_cb("🧹 Очистить", cbw("clear", r_id)));
    }
    if @8 *u_ret != 0 kb_row1(kb, btn_cb("⬅️ Назад", cbs("back", r_id)));
    else kb_row1(kb, btn_cb("🗑 Отмена", cbw("cancel", r_id)));
    panel_pic(uid, "media", sb_str(b), kb, fresh);
}

scr_artist(uid, fresh) {
    auto b;
    auto kb;
    b = qb("🎨 <b>Кто автор?</b>\n\nВыбери художника из списка — и если это ты, тоже найди себя там. Если автора нет в списке, предложи нового.\n\nСейчас: ");
    sb_add(b, artist_now());
    kb = ja();
    kb_row1(kb, btn_pick("🔎 Выбрать из списка"));
    kb_row2(kb, btn_cb("❔ Автор неизвестен", cbw("unk", r_id)), btn_cb("➕ Нет в списке", cbw("anew", r_id)));
    nav(kb, r_id, artist_set());
    panel_pic(uid, "artist", sb_str(b), kb, fresh);
}

scr_aname(uid, fresh) {
    auto kb;
    kb = ja();
    kb_row1(kb, btn_cb("⬅️ Назад", cbs("back", r_id)));
    panel_pic(uid, "artist_new", "➕ <b>Новый художник</b>\n\nНапиши имя или ник художника.", kb, fresh);
}

scr_alink(uid, fresh) {
    auto kb;
    kb = ja();
    kb_row1(kb, btn_cb("Пропустить", cbs("skip", r_id)));
    kb_row1(kb, btn_cb("⬅️ Назад", cbs("back", r_id)));
    panel_pic(uid, "artist_new", "🔗 <b>Ссылка на художника</b>\n\nПришли ссылку на его страницу или соцсеть, либо @ник в Telegram. Можно пропустить.", kb, fresh);
}

scr_chars(uid, fresh) {
    auto b;
    auto kb;
    auto q;
    auto i;
    auto n;
    auto row;
    auto name;
    auto cnt;

    // Выбранные братухи из справочника: читаем целиком до построения кнопок.
    q = qb("SELECT c.id, c.name FROM request_chars rc JOIN characters c ON c.id = rc.character_id WHERE rc.request_id = ");
    sb_int(q, r_id);
    sb_add(q, " ORDER BY c.name");
    b = qb("👥 <b>Кто изображён?</b>\n\nВыбирай братух из списка — по одному, до 10. Если братухи нет в списке, предложи нового.\n\nВыбрано: ");
    kb = ja();
    kb_row2(kb, btn_pick("🔎 Выбрать из списка"), btn_cb("➕ Нет в списке", cbw("chnew", r_id)));
    cnt = 0;
    row = 0;
    if db_exec(sb_str(q)) {
        for i = 0 i < db_rows() i++ {
            if cnt sb_add(b, ", ");
            sb_add(b, "<b>");
            sb_html(b, db_val(i, 1), 0);
            sb_add(b, "</b>");
            if (cnt & 1) == 0 {
                row = ja();
                jpush(kb, row);
            }
            jpush(row, btn_cb(x_label(db_val(i, 1)), cbw2("chdel", r_id, db_int(i, 0))));
            cnt++;
        }
    }
    n = l_count(r_nchars);
    for i = 0 i < n i++ {
        name = l_get(r_nchars, i);
        if cnt sb_add(b, ", ");
        sb_add(b, "🆕 <b>");
        sb_html(b, name, 0);
        sb_add(b, "</b>");
        if (cnt & 1) == 0 {
            row = ja();
            jpush(kb, row);
        }
        jpush(row, btn_cb(x_label(name), cbw2("chdelp", r_id, i)));
        cnt++;
    }
    if cnt == 0 sb_add(b, "пока никого");
    else sb_add(b, "\n\nНажми на братуху, чтобы убрать его.");
    nav(kb, r_id, 1);
    panel_pic(uid, "chars", sb_str(b), kb, fresh);
}

scr_cnew(uid, fresh) {
    auto kb;
    kb = jpush(ja(), jpush(ja(), btn_cb("⬅️ Назад", cbs("back", r_id))));
    panel_pic(uid, "chars_new", "➕ <b>Новые братухи</b>\n\nНапиши имена братух, которых нет в списке, через запятую (до 5). Админ проверит и добавит их.", kb, fresh);
}

scr_caption(uid, fresh) {
    auto b;
    auto kb;
    b = qb("📝 <b>Подпись</b>\n\nНапиши подпись к посту (до 500 символов) или пропусти.");
    kb = ja();
    if @8 *r_caption != 0 {
        sb_add(b, "\n\nСейчас: ");
        sb_html(b, s_cutc(r_caption, 200), 0);
        kb_row2(kb, btn_cb("Оставить", cbs("skip", r_id)), btn_cb("Убрать подпись", cbs("capdel", r_id)));
    } else kb_row1(kb, btn_cb("Пропустить", cbs("skip", r_id)));
    kb_row1(kb, btn_cb("⬅️ Назад", cbs("back", r_id)));
    panel_pic(uid, "caption", sb_str(b), kb, fresh);
}

scr_credit(uid, fresh) {
    auto kb;
    kb = ja();
    kb_row2(kb, btn_cb("Указать меня", cbw2("credit", r_id, 1)), btn_cb("Остаться анонимом", cbw2("credit", r_id, 0)));
    kb_row1(kb, btn_cb("⬅️ Назад", cbs("back", r_id)));
    panel_pic(uid, "credit", "✍️ <b>Подписать тебя в посте?</b>\n\nПо умолчанию пост выходит анонимно.", kb, fresh);
}

scr_review(uid, fresh) {
    auto b;
    auto kb;
    b = qb("👀 <b>Так будет выглядеть пост</b>\n\n");
    sb_add(b, post_html(post_limit()));
    kb = ja();
    kb_row1(kb, btn_cb("✅ Отправить на проверку", cbw("send", r_id)));
    kb_row2(kb, btn_cb("✏️ Изменить", cbw("edit", r_id)), btn_cb("🗑 Отмена", cbw("cancel", r_id)));
    panel(uid, sb_str(b), kb, fresh);
}

// Кнопка перехода на шаг из меню правки.
goto_btn(text, rid, step) {
    auto b;
    b = qb("w:goto:");
    sb_int(b, rid);
    sb_c(b, ':');
    sb_add(b, step);
    btn_cb(text, sb_str(b));
}

scr_edit(uid, fresh) {
    auto kb;
    kb = ja();
    kb_row2(kb, goto_btn("🖼 Содержимое", r_id, "media"), goto_btn("🎨 Художник", r_id, "artist"));
    // У текстовой работы подписи нет: сам текст и есть пост.
    if r_istext() kb_row1(kb, goto_btn("👥 Братухи", r_id, "chars"));
    else kb_row2(kb, goto_btn("👥 Братухи", r_id, "chars"), goto_btn("📝 Подпись", r_id, "caption"));
    kb_row1(kb, goto_btn("✍️ Подпись отправителя", r_id, "credit"));
    kb_row1(kb, btn_cb("⬅️ К просмотру", cbs("back", r_id)));
    panel_pic(uid, "edit", "✏️ <b>Что изменить?</b>", kb, fresh);
}

// --- заявка на художника или братуху ------------------------------------------

ent_title() {
    if s_eq(r_kind, "artist") return "🎨 <b>Новый художник</b>";
    "👤 <b>Новый братуха</b>";
}

// Баннер экранов заявки на художника или братуху.
ent_pic() {
    if s_eq(r_kind, "artist") return "artist_new";
    "chars_new";
}

scr_ename(uid, fresh) {
    auto b;
    auto kb;
    b = qb(ent_title());
    if s_eq(r_kind, "artist") sb_add(b, "\n\nНапиши имя или ник художника.");
    else sb_add(b, "\n\nНапиши имя братухи — так, как его будут искать в списке.");
    kb = ja();
    if @8 *u_ret != 0 kb_row1(kb, btn_cb("⬅️ Назад", cbs("back", r_id)));
    else kb_row1(kb, btn_cb("🗑 Отмена", cbw("cancel", r_id)));
    panel_pic(uid, ent_pic(), sb_str(b), kb, fresh);
}

scr_eextra(uid, fresh) {
    auto b;
    auto kb;
    b = qb(ent_title());
    if s_eq(r_kind, "artist") sb_add(b, "\n\nПришли ссылку на страницу или соцсеть художника, либо @ник в Telegram. Можно пропустить.");
    else sb_add(b, "\n\nНапиши псевдонимы и клички братухи через запятую — по ним его тоже найдут в списке. Можно пропустить.");
    kb = ja();
    kb_row1(kb, btn_cb("Пропустить", cbs("skip", r_id)));
    kb_row1(kb, btn_cb("⬅️ Назад", cbs("back", r_id)));
    panel_pic(uid, ent_pic(), sb_str(b), kb, fresh);
}

scr_enote(uid, fresh) {
    auto b;
    auto kb;
    b = qb(ent_title());
    sb_add(b, "\n\nПримечание для админа: кто это и где посмотреть. Можно пропустить.");
    kb = ja();
    kb_row1(kb, btn_cb("Пропустить", cbs("skip", r_id)));
    kb_row1(kb, btn_cb("⬅️ Назад", cbs("back", r_id)));
    panel_pic(uid, ent_pic(), sb_str(b), kb, fresh);
}

// Описание заявки на художника/братуху для экранов и карточек.
ent_summary(b) {
    sb_add(b, "Имя: <b>");
    sb_html(b, r_ename, 0);
    sb_add(b, "</b>");
    if @8 *r_eextra != 0 {
        if s_eq(r_kind, "artist") sb_add(b, "\nСсылка: ");
        else sb_add(b, "\nПсевдонимы: ");
        sb_html(b, r_eextra, 0);
    }
    if @8 *r_note != 0 {
        sb_add(b, "\nПримечание: ");
        sb_html(b, r_note, 0);
    }
    b;
}

scr_ereview(uid, fresh) {
    auto b;
    auto kb;
    b = qb(ent_title());
    sb_add(b, "\n\n");
    ent_summary(b);
    kb = ja();
    kb_row1(kb, btn_cb("✅ Отправить на проверку", cbw("send", r_id)));
    kb_row2(kb, btn_cb("✏️ Изменить", cbw("edit", r_id)), btn_cb("🗑 Отмена", cbw("cancel", r_id)));
    panel_pic(uid, ent_pic(), sb_str(b), kb, fresh);
}

scr_eedit(uid, fresh) {
    auto kb;
    kb = ja();
    kb_row2(kb, goto_btn("Имя", r_id, "ename"), goto_btn("Ссылка / псевдонимы", r_id, "eextra"));
    kb_row1(kb, goto_btn("Примечание", r_id, "enote"));
    kb_row1(kb, btn_cb("⬅️ К просмотру", cbs("back", r_id)));
    panel_pic(uid, "edit", "✏️ <b>Что изменить?</b>", kb, fresh);
}

// --- правка админом ------------------------------------------------------------

scr_afix(uid, fresh) {
    auto b;
    auto kb;
    b = qb("✏️ <b>Исправление заявки #");
    sb_int(b, r_id);
    sb_add(b, "</b>\n\n");
    kb = ja();
    if s_eq(r_kind, "work") {
        sb_add(b, post_html(post_limit()));
        kb_row2(kb, goto_btn("🎨 Художник", r_id, "artist"), goto_btn("👥 Братухи", r_id, "chars"));
        if !r_istext() kb_row1(kb, goto_btn("📝 Подпись", r_id, "caption"));
        if r_credit kb_row1(kb, btn_cb("✍️ Подпись отправителя: да", cbw2("credit", r_id, 0)));
        else kb_row1(kb, btn_cb("✍️ Подпись отправителя: нет", cbw2("credit", r_id, 1)));
    } else {
        ent_summary(b);
        kb_row2(kb, goto_btn("Имя", r_id, "ename"), goto_btn("Ссылка / псевдонимы", r_id, "eextra"));
        kb_row1(kb, goto_btn("Примечание", r_id, "enote"));
    }
    kb_row1(kb, btn_cb("✔ Готово", cbw("fixdone", r_id)));
    panel(uid, sb_str(b), kb, fresh);
}

// Показывает экран по текущему шагу пользователя (u_state, u_req).
show_step(uid, fresh) {
    auto st;
    st = u_state;
    if !rq_load(u_req) return 0;
    if s_eq(st, "w_media") return scr_media(uid, fresh);
    if s_eq(st, "w_artist") return scr_artist(uid, fresh);
    if s_eq(st, "w_aname") return scr_aname(uid, fresh);
    if s_eq(st, "w_alink") return scr_alink(uid, fresh);
    if s_eq(st, "w_chars") return scr_chars(uid, fresh);
    if s_eq(st, "w_cnew") return scr_cnew(uid, fresh);
    if s_eq(st, "w_caption") return scr_caption(uid, fresh);
    if s_eq(st, "w_credit") return scr_credit(uid, fresh);
    if s_eq(st, "w_review") return scr_review(uid, fresh);
    if s_eq(st, "w_edit") return scr_edit(uid, fresh);
    if s_eq(st, "e_name") return scr_ename(uid, fresh);
    if s_eq(st, "e_extra") return scr_eextra(uid, fresh);
    if s_eq(st, "e_note") return scr_enote(uid, fresh);
    if s_eq(st, "e_review") return scr_ereview(uid, fresh);
    if s_eq(st, "e_edit") return scr_eedit(uid, fresh);
    if s_eq(st, "a_fix") return scr_afix(uid, fresh);
    0;
}
