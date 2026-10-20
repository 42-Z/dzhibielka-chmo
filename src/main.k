// main.k: настройки из окружения и цикл long polling (getUpdates).

handle_update(upd) {
    auto m;
    m = jget(upd, "message");
    if m return on_message(m);
    m = jget(upd, "callback_query");
    if m return on_callback(m);
    m = jget(upd, "inline_query");
    if m return on_inline(m);
    0;
}

// Значение обязательной переменной окружения или выход с понятной ошибкой.
need_env(name) {
    auto v;
    v = env_or(name, 0);
    if !v {
        fprintf(stderr, "Не задана переменная окружения %s (см. .env.example)\n", name);
        exit(1);
    }
    v;
}

global main
main() {
    auto offset;
    auto req;
    auto root;
    auto updates;
    auto upd;
    auto n;
    auto i;
    auto id;
    auto token;

    token = need_env("BOT_TOKEN");
    cfg_channel = need_env("CHANNEL_ID");
    if cfg_admins(need_env("ADMIN_IDS")) == 0 {
        fprintf(stderr, "В ADMIN_IDS нет ни одного id\n");
        return 1;
    }
    arena_init();
    if !tg_init(token) {
        fprintf(stderr, "Не удалось инициализировать libcurl\n");
        return 1;
    }
    bot_name();  // ник бота нужен для ссылки в подписи постов; ошибка (например, токена) попадёт в журнал
    // Каталог баннеров и файл схемы постоянные, относительно каталога запуска.
    tg_pics = "assets/banners";
    if !pic_exists("menu") fprintf(stderr, "В %s нет баннеров — экраны будут без картинок\n", tg_pics);
    if !db_connect(need_env("DATABASE_URL")) return 1;
    if !db_schema("sql/schema.sql") return 1;
    nav_dirty = 1;  // после перезапуска сверяем навигационный пост со справочником
    nav_flush();

    // Telegram не даёт боту писать первым: админ, не нажимавший /start, карточек не получит.
    for i = 0 i < cfg_admin_n i++ {
        root = tg_post("getChat", jseti(jo(), "chat_id", cfg_admin[i]), 15);
        if !root fprintf(stderr, "Админ %lld ещё не писал боту /start — карточки заявок ему не дойдут\n", cfg_admin[i]);
        json_release(root);
    }

    fprintf(stderr, "Бот запущен, жду сообщения (Ctrl+C — выход)\n");
    offset = 0;
    while 1 {
        // offset подтверждает обработанные update: Telegram не отдаёт их повторно.
        arena_reset();
        req = jseti(jseti(jo(), "offset", offset), "timeout", 30);
        jset(req, "allowed_updates", jpush(jpush(jpush(ja(), json_string("message")), json_string("callback_query")), json_string("inline_query")));
        root = tg_post("getUpdates", req, 40);
        if !root {
            sleep(5);
            continue;
        }
        updates = jget(root, "result");
        n = json_array_size(updates);
        for i = 0 i < n i++ {
            upd = json_array_get(updates, i);
            id = jint(upd, "update_id");
            handle_update(upd);
            nav_flush();  // пост в канале сверяем до того, как update подтвердится
            if id >= offset offset = id + 1;
            arena_reset();
        }
        json_release(root);
    }
}
