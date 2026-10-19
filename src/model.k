// model.k: настройки, пользователи, заявки, художники и герои.
//
// «Текущая заявка» и «текущая запись справочника» живут в глобальных переменных
// r_* и ent_*: rq_load/artist_get/... заполняют их, строки копируются на арену.
// Загрузка другой заявки затирает предыдущую, поэтому нужные поля берите сразу.

cfg_channel;      // CHANNEL_ID: «-100…» или «@имя»
cfg_admin[16];    // ADMIN_IDS
cfg_admin_n;

u_state;          // шаг диалога текущего пользователя (users.state)
u_req;            // заявка, с которой связан шаг
u_ret;            // куда вернуться после правки шага
u_panel;          // id панели в чате с ботом
u_pic;            // баннер панели: имя картинки или "" у текстовой панели
u_group;          // media_group_id последнего принятого альбома

r_id; r_kind; r_user; r_status; r_items; r_artist; r_mode; r_nart; r_nlink;
r_nchars; r_caption; r_credit; r_ename; r_eextra; r_note; r_reason; r_link;
r_uname; r_ufirst;

ent_id; ent_name; ent_link; ent_x;  // ent_x: tg_id художника или хэштег героя

// Строка или значение по умолчанию, если строки нет.
nz(s, d) {
    if s return s;
    d;
}

// Начало запроса: строитель с уже записанным началом.
qb(s) sb_add(sb_new(), s);

// Читает ADMIN_IDS («123,456») в cfg_admin.
cfg_admins(s) {
    auto c;
    auto n;
    auto have;
    cfg_admin_n = 0;
    n = 0;
    have = 0;
    while 1 {
        c = @8 *s;
        if (c >= '0') & (c <= '9') {
            n = n * 10 + c - '0';
            have = 1;
        } else {
            if have & (cfg_admin_n < 16) {
                cfg_admin[cfg_admin_n] = n;
                cfg_admin_n++;
            }
            n = 0;
            have = 0;
        }
        if c == 0 break;
        s++;
    }
    cfg_admin_n;
}

is_admin(uid) {
    auto i;
    for i = 0 i < cfg_admin_n i++ {
        if cfg_admin[i] == uid return 1;
    }
    0;
}

// Ссылка вида https://… или 0 для явно неподходящей строки. Принимает «@ник»
// (Telegram), «t.me/ник», «vk.com/…» и полные адреса.
link_norm(s) {
    auto b;
    s = s_trim(s);
    if @8 *s == 0 return "";
    // Длинная ссылка не поместилась бы в сообщения бота (лимит 4096 символов).
    if s_chars(s) > 200 return "";
    if (s_starts(s, "http://")) | (s_starts(s, "https://")) return s;
    b = sb_new();
    if @8 *s == '@' {
        sb_add(b, "https://t.me/");
        sb_add(b, s + 1);
        return sb_str(b);
    }
    if (strchr(s, '.') != 0) & (strchr(s, ' ') == 0) {
        sb_add(b, "https://");
        sb_add(b, s);
        return sb_str(b);
    }
    "";
}

// --- пользователи --------------------------------------------------------------

// Создаёт или обновляет строку пользователя по объекту from из update.
user_touch(from) {
    auto q;
    q = qb("INSERT INTO users (id, username, first_name) VALUES (");
    sb_int(q, jint(from, "id"));
    sb_add(q, ", ");
    sb_lit(q, nz(jstr(from, "username"), ""));
    sb_add(q, ", ");
    sb_lit(q, nz(jstr(from, "first_name"), ""));
    sb_add(q, ") ON CONFLICT (id) DO UPDATE SET username = EXCLUDED.username, first_name = EXCLUDED.first_name");
    db_exec(sb_str(q));
}

// Загружает сеанс пользователя в u_*.
u_load(uid) {
    auto q;
    q = qb("SELECT state, COALESCE(req_id, 0), ret, panel_msg, last_group, panel_pic FROM users WHERE id = ");
    sb_int(q, uid);
    u_state = "";
    u_req = 0;
    u_ret = "";
    u_panel = 0;
    u_pic = "";
    u_group = "";
    if !db_exec(sb_str(q)) return 0;
    if db_rows() < 1 return 0;
    u_state = s_dup(db_val(0, 0));
    u_req = db_int(0, 1);
    u_ret = s_dup(db_val(0, 2));
    u_panel = db_int(0, 3);
    u_group = s_dup(db_val(0, 4));
    u_pic = s_dup(db_val(0, 5));
    1;
}

u_set(uid, state, req, ret) {
    auto q;
    q = qb("UPDATE users SET state = ");
    sb_lit(q, state);
    sb_add(q, ", req_id = NULLIF(");
    sb_int(q, req);
    sb_add(q, ", 0), ret = ");
    sb_lit(q, ret);
    sb_add(q, " WHERE id = ");
    sb_int(q, uid);
    u_state = state;
    u_req = req;
    u_ret = ret;
    db_exec(sb_str(q));
}

// Запоминает панель: id сообщения и имя её баннера ("" — обычный текст).
u_set_panel(uid, mid, pic) {
    auto q;
    q = qb("UPDATE users SET panel_msg = ");
    sb_int(q, mid);
    sb_add(q, ", panel_pic = ");
    sb_lit(q, pic);
    sb_add(q, " WHERE id = ");
    sb_int(q, uid);
    u_panel = mid;
    u_pic = pic;
    db_exec(sb_str(q));
}

u_set_group(uid, g) {
    auto q;
    q = qb("UPDATE users SET last_group = ");
    sb_lit(q, g);
    sb_add(q, " WHERE id = ");
    sb_int(q, uid);
    u_group = g;
    db_exec(sb_str(q));
}

// --- заявки --------------------------------------------------------------------

// Создаёт черновик заявки; возвращает её id (0 при ошибке).
rq_new(uid, kind) {
    auto q;
    q = qb("INSERT INTO requests (kind, user_id) VALUES (");
    sb_lit(q, kind);
    sb_add(q, ", ");
    sb_int(q, uid);
    sb_add(q, ") RETURNING id");
    if !db_exec(sb_str(q)) return 0;
    db_int(0, 0);
}

// Загружает заявку в r_*; 0, если такой нет.
rq_load(id) {
    auto q;
    q = qb("SELECT r.id, r.kind, r.user_id, r.status, r.items::text, COALESCE(r.artist_id, 0), r.artist_mode, ");
    sb_add(q, "r.new_artist, r.new_artist_link, r.new_chars, r.caption, r.credit::int, r.ent_name, r.ent_extra, ");
    sb_add(q, "r.note, r.reason, r.channel_link, u.username, u.first_name ");
    sb_add(q, "FROM requests r JOIN users u ON u.id = r.user_id WHERE r.id = ");
    sb_int(q, id);
    if !db_exec(sb_str(q)) return 0;
    if db_rows() < 1 return 0;
    r_id = db_int(0, 0);
    r_kind = s_dup(db_val(0, 1));
    r_user = db_int(0, 2);
    r_status = s_dup(db_val(0, 3));
    r_items = s_dup(db_val(0, 4));
    r_artist = db_int(0, 5);
    r_mode = s_dup(db_val(0, 6));
    r_nart = s_dup(db_val(0, 7));
    r_nlink = s_dup(db_val(0, 8));
    r_nchars = s_dup(db_val(0, 9));
    r_caption = s_dup(db_val(0, 10));
    r_credit = db_int(0, 11);
    r_ename = s_dup(db_val(0, 12));
    r_eextra = s_dup(db_val(0, 13));
    r_note = s_dup(db_val(0, 14));
    r_reason = s_dup(db_val(0, 15));
    r_link = s_dup(db_val(0, 16));
    r_uname = s_dup(db_val(0, 17));
    r_ufirst = s_dup(db_val(0, 18));
    1;
}

// Меняет одну строковую колонку заявки (col — имя из кода, не пользовательский ввод).
rq_set_s(id, col, val) {
    auto q;
    q = qb("UPDATE requests SET ");
    sb_add(q, col);
    sb_add(q, " = ");
    sb_lit(q, val);
    sb_add(q, " WHERE id = ");
    sb_int(q, id);
    db_exec(sb_str(q));
}

// Число в колонку; 0 пишется как NULL (для artist_id).
rq_set_i(id, col, n) {
    auto q;
    q = qb("UPDATE requests SET ");
    sb_add(q, col);
    sb_add(q, " = NULLIF(");
    sb_int(q, n);
    sb_add(q, ", 0) WHERE id = ");
    sb_int(q, id);
    db_exec(sb_str(q));
}

rq_set_credit(id, on) {
    auto q;
    q = qb("UPDATE requests SET credit = ");
    if on sb_add(q, "true");
    else sb_add(q, "false");
    sb_add(q, " WHERE id = ");
    sb_int(q, id);
    db_exec(sb_str(q));
}

// Добавляет элемент работы (не больше 10). Истина, если добавился.
rq_item_add(id, type, file, text) {
    auto q;
    q = qb("UPDATE requests SET items = items || jsonb_build_array(jsonb_build_object('t', ");
    sb_lit(q, type);
    sb_add(q, ", 'f', ");
    sb_lit(q, file);
    sb_add(q, ", 'x', ");
    sb_lit(q, text);
    sb_add(q, ")) WHERE id = ");
    sb_int(q, id);
    sb_add(q, " AND jsonb_array_length(items) < 10");
    if !db_exec(sb_str(q)) return 0;
    db_changed() > 0;
}

rq_items_clear(id) {
    auto q;
    q = qb("UPDATE requests SET items = '[]' WHERE id = ");
    sb_int(q, id);
    db_exec(sb_str(q));
}

rq_char_add(id, cid) {
    auto q;
    q = qb("INSERT INTO request_chars (request_id, character_id) VALUES (");
    sb_int(q, id);
    sb_add(q, ", ");
    sb_int(q, cid);
    sb_add(q, ") ON CONFLICT DO NOTHING");
    db_exec(sb_str(q));
}

rq_char_del(id, cid) {
    auto q;
    q = qb("DELETE FROM request_chars WHERE request_id = ");
    sb_int(q, id);
    sb_add(q, " AND character_id = ");
    sb_int(q, cid);
    db_exec(sb_str(q));
}

// Сколько героев выбрано (из справочника и предложенных новых).
rq_char_count(id) {
    auto q;
    q = qb("SELECT count(*) FROM request_chars WHERE request_id = ");
    sb_int(q, id);
    if !db_exec(sb_str(q)) return 0;
    db_int(0, 0);
}

// --- справочники ---------------------------------------------------------------

ent_read() {
    if db_rows() < 1 return 0;
    ent_id = db_int(0, 0);
    ent_name = s_dup(db_val(0, 1));
    ent_link = s_dup(db_val(0, 2));
    ent_x = s_dup(db_val(0, 3));
    1;
}

artist_get(id) {
    auto q;
    q = qb("SELECT id, name, link, COALESCE(tg_id, 0)::text FROM artists WHERE id = ");
    sb_int(q, id);
    if !db_exec(sb_str(q)) return 0;
    ent_read();
}

// Художник по имени без учёта регистра.
artist_find(name) {
    auto q;
    q = qb("SELECT id, name, link, COALESCE(tg_id, 0)::text FROM artists WHERE name_key = ");
    sb_lit(q, s_lower(s_trim(name)));
    if !db_exec(sb_str(q)) return 0;
    ent_read();
}

// Художник, связанный с пользователем Telegram.
artist_of_user(uid) {
    auto q;
    q = qb("SELECT id, name, link, tg_id::text FROM artists WHERE tg_id = ");
    sb_int(q, uid);
    if !db_exec(sb_str(q)) return 0;
    ent_read();
}

// Добавляет художника (или находит с тем же именем); возвращает id, 0 при ошибке.
artist_add(name, link, tgid) {
    auto q;
    name = s_trim(name);
    q = qb("INSERT INTO artists (name, name_key, link, tg_id) VALUES (");
    sb_lit(q, name);
    sb_add(q, ", ");
    sb_lit(q, s_lower(name));
    sb_add(q, ", ");
    sb_lit(q, link);
    sb_add(q, ", NULLIF(");
    sb_int(q, tgid);
    sb_add(q, ", 0)) ON CONFLICT (name_key) DO UPDATE SET ");
    sb_add(q, "link = CASE WHEN artists.link = '' THEN EXCLUDED.link ELSE artists.link END, ");
    sb_add(q, "tg_id = COALESCE(artists.tg_id, EXCLUDED.tg_id) RETURNING id");
    if !db_exec(sb_str(q)) return 0;
    db_int(0, 0);
}

char_get(id) {
    auto q;
    q = qb("SELECT id, name, aliases, tag FROM characters WHERE id = ");
    sb_int(q, id);
    if !db_exec(sb_str(q)) return 0;
    ent_read();
}

char_find(name) {
    auto q;
    q = qb("SELECT id, name, aliases, tag FROM characters WHERE name_key = ");
    sb_lit(q, s_lower(s_trim(name)));
    if !db_exec(sb_str(q)) return 0;
    ent_read();
}

// Добавляет героя (или находит с тем же именем); возвращает id, 0 при ошибке.
char_add(name, aliases) {
    auto q;
    auto key;
    name = s_trim(name);
    aliases = s_trim(aliases);
    key = s_lower(name);
    q = qb("INSERT INTO characters (name, name_key, aliases, search, tag) VALUES (");
    sb_lit(q, name);
    sb_add(q, ", ");
    sb_lit(q, key);
    sb_add(q, ", ");
    sb_lit(q, aliases);
    sb_add(q, ", ");
    sb_lit(q, s_lower(l_add(name, aliases)));
    sb_add(q, ", ");
    sb_lit(q, s_tag(name));
    sb_add(q, ") ON CONFLICT (name_key) DO UPDATE SET ");
    sb_add(q, "aliases = CASE WHEN characters.aliases = '' THEN EXCLUDED.aliases ELSE characters.aliases END, ");
    sb_add(q, "search = CASE WHEN characters.aliases = '' THEN EXCLUDED.search ELSE characters.search END ");
    sb_add(q, "RETURNING id");
    if !db_exec(sb_str(q)) return 0;
    db_int(0, 0);
}
