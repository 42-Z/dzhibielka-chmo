// post.k: текст поста для канала и отправка работы в Bot API.
//
// Пост — подпись пользователя цитатой, затем строки с художником и братухами (метки
// жирным), хэштеги, (по желанию отправителя) его имя и внизу подпись канала со ссылкой
// на бота. У текстовой работы сам текст не оформляется цитатой: это не подпись, а
// содержимое. Лимиты Telegram: подпись к медиа 1024 символа, текст сообщения 4096;
// считаются в единицах UTF-16, поэтому длину видимого текста (без тегов) ведём отдельно
// (post_vis), а подпись пользователя обрезаем под остаток.

post_vis;       // видимая длина строки, которую сейчас собирают
pm_artist; pm_artist_v;
pm_chars; pm_chars_v;
pm_tags; pm_tags_v;
pm_credit; pm_credit_v;
bot_user;       // имя бота без «@» (getMe) или 0, пока узнать не удалось

// Имя бота для ссылки в подписи поста: спрашивает Telegram один раз и запоминает.
bot_name() {
    auto root;
    auto u;
    if bot_user return bot_user;
    root = tg_post("getMe", jo(), 15);
    if root {
        u = jstr(jget(root, "result"), "username");
        if u bot_user = strdup(u);  // живёт всё время работы бота, арена сбрасывается после каждого update
        json_release(root);
    }
    bot_user;
}

// Подпись внизу поста: «42 Confession | Предложка», «Предложка» — ссылка на бота (если ник известен).
post_footer() {
    auto b;
    b = qb("42 Confession | ");
    if bot_name() {
        sb_add(b, "<a href=\"https://t.me/");
        sb_add(b, bot_name());
        sb_add(b, "\">Предложка</a>");
    } else sb_add(b, "Предложка");
    sb_str(b);
}

// Метка строки поста: «🎨 <b>Художник:</b> » — метка жирным; видимая длина считается без тегов.
plabel(b, icon, label) {
    sb_add(b, icon);
    sb_add(b, " <b>");
    sb_add(b, label);
    sb_add(b, "</b> ");
    post_vis = post_vis + s_u16(icon) + 1 + s_u16(label) + 1;
    b;
}

// Добавляет в b текст s с экранированием HTML и учитывает видимую длину.
pv(b, s) {
    sb_html(b, s, 0);
    post_vis = post_vis + s_u16(s);
    b;
}

// То же для служебного текста без спецсимволов.
pp(b, s) {
    sb_add(b, s);
    post_vis = post_vis + s_u16(s);
    b;
}

// Имя со ссылкой, если она есть.
pv_link(b, name, link) {
    if @8 *link != 0 {
        sb_add(b, "<a href=\"");
        sb_html(b, link, 1);
        sb_add(b, "\">");
        pv(b, name);
        sb_add(b, "</a>");
    } else pv(b, name);
    b;
}

// Первый элемент работы (разобранный JSON) или 0.
post_first(items) {
    if !items return 0;
    json_array_get(items, 0);
}

// Собирает строки поста по загруженной заявке (r_*) в pm_*.
post_lines() {
    auto b;
    auto tb;
    auto n;
    auto i;
    auto q;
    auto name;

    // художник
    b = sb_new();
    post_vis = 0;
    plabel(b, "🎨", "Художник:");
    if r_artist {
        artist_get(r_artist);
        pv_link(b, ent_name, ent_link);
    } else if (@8 *r_mode == 0) | s_eq(r_mode, "unknown") {
        pp(b, "неизвестен");
    } else pv_link(b, r_nart, r_nlink);
    pm_artist = sb_str(b);
    pm_artist_v = post_vis;

    // братухи из справочника и предложенные новые
    q = qb("SELECT c.name, c.tag FROM request_chars rc JOIN characters c ON c.id = rc.character_id WHERE rc.request_id = ");
    sb_int(q, r_id);
    sb_add(q, " ORDER BY c.name");
    b = sb_new();
    tb = sb_new();
    post_vis = 0;
    plabel(b, "👥", "Братухи:");
    sb_add(tb, "#42братухи");
    n = 0;
    if db_exec(sb_str(q)) {
        for i = 0 i < db_rows() i++ {
            if n pp(b, ", ");
            pv(b, db_val(i, 0));
            if @8 *db_val(i, 1) != 0 {
                sb_add(tb, " #");
                sb_add(tb, db_val(i, 1));
            }
            n++;
        }
    }
    for i = 0 i < l_count(r_nchars) i++ {
        name = l_get(r_nchars, i);
        if n pp(b, ", ");
        pv(b, name);
        if @8 *s_tag(name) != 0 {
            sb_add(tb, " #");
            sb_add(tb, s_tag(name));
        }
        n++;
    }
    pm_chars = "";
    pm_chars_v = 0;
    if n {
        pm_chars = sb_str(b);
        pm_chars_v = post_vis;
    }
    pm_tags = sb_str(tb);
    pm_tags_v = s_u16(pm_tags);

    // подпись отправителя
    pm_credit = "";
    pm_credit_v = 0;
    if r_credit {
        b = sb_new();
        post_vis = 0;
        pp(b, "✍️ Предложил(а): ");
        if @8 *r_uname != 0 {
            pp(b, "@");
            pv(b, r_uname);
        } else pv(b, r_ufirst);
        pm_credit = sb_str(b);
        pm_credit_v = post_vis;
    }
    0;
}

// Текст поста (HTML) для загруженной заявки на работу. limit — максимум видимых
// символов: подпись пользователя обрезается, при нехватке места убираются хэштеги.
post_html(limit) {
    auto items;
    auto first;
    auto body;
    auto out;
    auto meta;
    auto room;
    auto is_text;
    auto footer;

    post_lines();
    items = json_loads(r_items, 0, 0);
    first = post_first(items);
    body = r_caption;
    is_text = s_eq(nz(jstr(first, "t"), ""), "text");
    // Строки из items живут до json_release, поэтому тело копируем на арену.
    if is_text body = s_dup(nz(jstr(first, "x"), ""));
    json_release(items);
    footer = post_footer();

    // Длина служебных строк (вместе с пустой строкой и подписью внизу); если с полным
    // списком хэштегов остаётся меньше 40 символов под подпись, оставляем один общий тег.
    meta = pm_artist_v + 2 + s_u16("42 Confession | Предложка");
    if pm_chars_v meta = meta + 1 + pm_chars_v;
    if pm_credit_v meta = meta + 1 + pm_credit_v;
    if meta + 1 + pm_tags_v + 40 > limit {
        pm_tags = "#42братухи";
        pm_tags_v = 10;
    }
    meta = meta + 1 + pm_tags_v;
    room = 0;
    if meta + 2 < limit room = limit - meta - 2;

    out = sb_new();
    if (@8 *body != 0) & (room > 0) {
        if is_text {
            sb_html(out, s_cutc(body, room), 0);
            sb_add(out, "\n\n");
        } else {
            sb_add(out, "<blockquote>");
            sb_html(out, s_cutc(body, room), 0);
            sb_add(out, "</blockquote>\n");
        }
    }
    sb_add(out, pm_artist);
    if pm_chars_v {
        sb_c(out, '\n');
        sb_add(out, pm_chars);
    }
    sb_c(out, '\n');
    sb_add(out, pm_tags);
    if pm_credit_v {
        sb_c(out, '\n');
        sb_add(out, pm_credit);
    }
    sb_add(out, "\n\n");
    sb_add(out, footer);
    sb_str(out);
}

// Лимит видимых символов для заявки: у чистого текста 4096, у медиа подпись 1024.
post_limit() {
    auto items;
    auto first;
    auto lim;
    items = json_loads(r_items, 0, 0);
    first = post_first(items);
    lim = 1000;
    if s_eq(nz(jstr(first, "t"), ""), "text") lim = 4000;
    json_release(items);
    lim;
}

// Метод Bot API для одиночного медиа.
tp_method(t) {
    if s_eq(t, "photo") return "sendPhoto";
    if s_eq(t, "video") return "sendVideo";
    if s_eq(t, "animation") return "sendAnimation";
    "sendDocument";
}

// Отправляет работу (r_items) в чат chat (строка: id или @имя). html — подпись
// или, для текстовой работы, весь текст. Возвращает id первого сообщения или 0;
// причина ошибки остаётся в tg_last_err.
send_work(chat, html) {
    auto items;
    auto n;
    auto first;
    auto t;
    auto req;
    auto root;
    auto media;
    auto it;
    auto i;
    auto m;
    auto id;

    items = json_loads(r_items, 0, 0);
    n = json_array_size(items);
    if n == 0 {
        json_release(items);
        tg_last_err = "в заявке нет содержимого";
        return 0;
    }
    first = json_array_get(items, 0);
    t = nz(jstr(first, "t"), "");

    req = jsets(jo(), "chat_id", chat);
    if s_eq(t, "text") {
        jsets(req, "text", html);
        jsets(req, "parse_mode", "HTML");
        jset(req, "link_preview_options", jsetb(jo(), "is_disabled", 1));
        root = tg_post("sendMessage", req, 30);
        id = jint(jget(root, "result"), "message_id");
    } else if n == 1 {
        jsets(req, t, jstr(first, "f"));
        if @8 *html != 0 {
            jsets(req, "caption", html);
            jsets(req, "parse_mode", "HTML");
        }
        root = tg_post(tp_method(t), req, 60);
        id = jint(jget(root, "result"), "message_id");
    } else {
        media = ja();
        for i = 0 i < n i++ {
            it = json_array_get(items, i);
            m = jsets(jsets(jo(), "type", jstr(it, "t")), "media", jstr(it, "f"));
            if (i == 0) & (@8 *html != 0) {
                jsets(m, "caption", html);
                jsets(m, "parse_mode", "HTML");
            }
            jpush(media, m);
        }
        jset(req, "media", media);
        root = tg_post("sendMediaGroup", req, 90);
        id = jint(json_array_get(jget(root, "result"), 0), "message_id");
    }
    json_release(root);
    json_release(items);
    id;
}

// Ссылка на пост в канале по id сообщения (пусто, если канал не публичный и не -100…).
post_link(mid) {
    auto b;
    b = sb_new();
    if @8 *cfg_channel == '@' {
        sb_add(b, "https://t.me/");
        sb_add(b, cfg_channel + 1);
    } else if s_starts(cfg_channel, "-100") {
        sb_add(b, "https://t.me/c/");
        sb_add(b, cfg_channel + 4);
    } else return "";
    sb_c(b, '/');
    sb_int(b, mid);
    sb_str(b);
}
