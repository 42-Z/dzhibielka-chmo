-- Схема БД бота-предложки. Бот применяет файл при каждом старте, поэтому все
-- объекты создаются с IF NOT EXISTS. Ключи поиска (name_key, search) считает бот:
-- lower() в Postgres зависит от локали базы и кириллицу может не понимать.

CREATE TABLE IF NOT EXISTS users (
    id          bigint PRIMARY KEY,
    username    text NOT NULL DEFAULT '',
    first_name  text NOT NULL DEFAULT '',
    state       text NOT NULL DEFAULT '',      -- шаг диалога; пусто — нет активного
    req_id      bigint,                        -- заявка, к которой относится шаг
    ret         text NOT NULL DEFAULT '',      -- куда вернуться после правки шага
    panel_msg   bigint NOT NULL DEFAULT 0,     -- id панели в чате с ботом
    panel_pic   text NOT NULL DEFAULT '',      -- баннер панели; пусто — панель без картинки
    last_group  text NOT NULL DEFAULT '',      -- media_group_id последнего принятого альбома
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Для баз, созданных до появления баннеров.
ALTER TABLE users ADD COLUMN IF NOT EXISTS panel_pic text NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS artists (
    id          bigserial PRIMARY KEY,
    name        text NOT NULL,
    name_key    text NOT NULL UNIQUE,
    link        text NOT NULL DEFAULT '',
    tag         text NOT NULL DEFAULT '',      -- хэштег без «#»; пусто — бот берёт его из имени
    created_at  timestamptz NOT NULL DEFAULT now()
);

-- Для баз, созданных до хэштегов художников.
ALTER TABLE artists ADD COLUMN IF NOT EXISTS tag text NOT NULL DEFAULT '';

CREATE TABLE IF NOT EXISTS characters (
    id          bigserial PRIMARY KEY,
    name        text NOT NULL,
    name_key    text NOT NULL UNIQUE,
    aliases     text NOT NULL DEFAULT '',
    search      text NOT NULL,                 -- имя и псевдонимы в нижнем регистре
    tag         text NOT NULL DEFAULT '',      -- хэштег без «#»
    created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS requests (
    id              bigserial PRIMARY KEY,
    kind            text NOT NULL CHECK (kind IN ('work', 'artist', 'character')),
    user_id         bigint NOT NULL REFERENCES users (id),
    status          text NOT NULL DEFAULT 'draft'
                    CHECK (status IN ('draft', 'pending', 'approved', 'rejected')),
    -- работа: [{"t": "photo|video|animation|document|text", "f": "<file_id>", "x": "<текст>"}]
    items           jsonb NOT NULL DEFAULT '[]',
    artist_id       bigint REFERENCES artists (id),
    artist_mode     text NOT NULL DEFAULT '',  -- '', list, unknown, new
    -- Предложенные новые художник и братухи живут в черновике; при отправке работы каждый
    -- становится отдельной заявкой (parent_id), а из самой работы они убираются.
    new_artist      text NOT NULL DEFAULT '',
    new_artist_link text NOT NULL DEFAULT '',
    new_chars       text NOT NULL DEFAULT '',  -- предложенные братухи, по одному в строке
    caption         text NOT NULL DEFAULT '',
    credit          boolean NOT NULL DEFAULT false,  -- подписать отправителя в посте
    ent_name        text NOT NULL DEFAULT '',  -- заявка на художника/братуху: имя
    ent_extra       text NOT NULL DEFAULT '',  -- ссылка (художник) или псевдонимы (братуха)
    note            text NOT NULL DEFAULT '',  -- примечание для админа
    reason          text NOT NULL DEFAULT '',  -- причина отказа
    channel_link    text NOT NULL DEFAULT '',  -- ссылка на опубликованный пост
    -- заявка на художника/братуху, выделенная из заявки на работу: работа уйдёт админам
    -- на проверку, когда решены все такие заявки
    parent_id       bigint REFERENCES requests (id) ON DELETE SET NULL,
    decided_by      bigint,
    created_at      timestamptz NOT NULL DEFAULT now(),
    decided_at      timestamptz
);

-- Для баз, созданных до раздельного рассмотрения новых художников и братух.
ALTER TABLE requests ADD COLUMN IF NOT EXISTS parent_id bigint REFERENCES requests (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS requests_user_idx ON requests (user_id, id DESC);
CREATE INDEX IF NOT EXISTS requests_parent_idx ON requests (parent_id);
CREATE INDEX IF NOT EXISTS requests_status_idx ON requests (status);

CREATE TABLE IF NOT EXISTS request_chars (
    request_id   bigint NOT NULL REFERENCES requests (id) ON DELETE CASCADE,
    character_id bigint NOT NULL REFERENCES characters (id),
    PRIMARY KEY (request_id, character_id)
);

-- Карточка заявки у каждого админа.
CREATE TABLE IF NOT EXISTS cards (
    request_id  bigint NOT NULL REFERENCES requests (id) ON DELETE CASCADE,
    admin_id    bigint NOT NULL,
    message_id  bigint NOT NULL,
    PRIMARY KEY (request_id, admin_id)
);
