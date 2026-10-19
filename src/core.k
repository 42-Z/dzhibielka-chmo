// Бот-предложка канала «42 CONFESSION» на Kiva.
//
// Исходники лежат в src/*.k и склеиваются Makefile в build/bot.k: модулей в
// Kiva нет, все имена общие, порядок файлов не важен. В Kiva нет типов: всё — 64-битные слова, константы
// C-библиотек записаны числами, указатели передаются как есть. Операторов && и ||
// нет: условия собираются через & и | над сравнениями в скобках (у & и | приоритет
// выше, чем у сравнений, и они побитовые: операнды обязаны быть 0 или 1, поэтому
// «(c = f()) & …» писать нельзя — только «((c = f()) != 0) & …»). Сравнения беззнаковые, int-результаты C-функций
// маскируются & 0xFFFFFFFF. Вызовы C-функций с более чем шестью аргументами
// компилятор передаёт неверно, поэтому везде не больше шести.
//
// core.k: все extern, окружение, арена памяти, строки и UTF-8.

extern getenv
extern free
extern malloc
extern exit
extern sleep
extern fclose
extern fprintf
extern stderr
extern strlen
extern strcmp
extern strncmp
extern strchr
extern strstr
extern memcpy
extern atoll
extern snprintf
extern open_memstream
extern fopen
extern fread
extern fseek
extern ftell
extern curl_global_init
extern curl_easy_init
extern curl_easy_reset
extern curl_easy_setopt
extern curl_easy_perform
extern curl_easy_getinfo
extern curl_easy_strerror
extern curl_slist_append
extern json_object
extern json_array
extern json_string
extern json_integer
extern json_true
extern json_false
extern json_loads
extern json_dumps
extern json_delete
extern json_deep_copy
extern json_equal
extern json_object_set_new
extern json_array_append_new
extern json_object_get
extern json_array_get
extern json_array_size
extern json_integer_value
extern json_string_value
extern PQconnectdb
extern PQstatus
extern PQerrorMessage
extern PQreset
extern PQexec
extern PQresultStatus
extern PQresultErrorMessage
extern PQntuples
extern PQgetvalue
extern PQgetisnull
extern PQcmdTuples
extern PQclear
extern PQescapeLiteral
extern PQfreemem

arena_base;  // буфер арены: временные строки и структуры одного update
arena_pos;   // сколько байт арены занято
arena_cap;   // размер арены
numbuf[4];   // место для печати числа

// Значение переменной окружения; пустая строка считается незаданной.
env_or(name, fallback) {
    auto v;
    v = getenv(name);
    if !v return fallback;
    if @8 *v == 0 return fallback;
    v;
}

// Конец работы с сообщением: журнал в stderr и выход (процесс перезапускает супервизор).
die(msg) {
    fprintf(stderr, "%s\n", msg);
    exit(1);
}

// Арена: всё временное (строки, JSON-тексты, SQL) живёт до arena_reset() и не
// освобождается по одному. arena_reset() вызывается после каждого update.
arena_init() {
    arena_cap = 4194304;
    arena_base = malloc(arena_cap);
    if !arena_base die("не хватает памяти");
    arena_pos = 0;
    0;
}

arena_reset() {
    arena_pos = 0;
    0;
}

alloc(n) {
    auto p;
    n = (n + 15) & ~15;
    if arena_pos + n > arena_cap die("арена переполнена");
    p = arena_base + arena_pos;
    arena_pos = arena_pos + n;
    p;
}

s_ndup(s, n) {
    auto p;
    p = alloc(n + 1);
    memcpy(p, s, n);
    *(p + n) !8 0;
    p;
}

s_dup(s) s_ndup(s, strlen(s));

// Содержимое файла целиком на арене (0, если файл не открылся).
read_file(path) {
    auto f;
    auto n;
    auto s;
    f = fopen(path, "rb");
    if !f return 0;
    fseek(f, 0, 2);  // SEEK_END
    n = ftell(f);
    fseek(f, 0, 0);  // SEEK_SET
    s = alloc(n + 1);
    n = fread(s, 1, n, f);
    *(s + n) !8 0;
    fclose(f);
    s;
}

s_eq(a, b) !(strcmp(a, b) & 0xFFFFFFFF);

// Истина, если s начинается с p.
s_starts(s, p) !(strncmp(s, p, strlen(p)) & 0xFFFFFFFF);

// Истина, если p встречается в s.
s_has(s, p) strstr(s, p) != 0;

// Пробел, табуляция, перевод строки или возврат каретки ('\r' компилятор не знает).
is_blank(c) (c == ' ') | (c == '\n') | (c == '\t') | (c == 13);

// Копия s без пробельных символов по краям.
s_trim(s) {
    auto a;
    auto b;
    a = 0;
    b = strlen(s);
    while (a < b) & is_blank(@8 *(s + a)) a++;
    while (b > a) & is_blank(@8 *(s + b - 1)) b--;
    s_ndup(s + a, b - a);
}

// Обрезает s до max байт по границе UTF-8-символа (иначе json_string вернёт NULL).
s_cut(s, max) {
    auto n;
    n = strlen(s);
    if n <= max return s;
    while (max > 0) & ((@8 *(s + max) & 0xC0) == 0x80) max--;
    s_ndup(s, max);
}

// Обрезает s до max символов (не байт).
s_cutc(s, max) {
    auto i;
    auto n;
    auto c;
    i = 0;
    n = 0;
    while c = @8 *(s + i) {
        if (c & 0xC0) != 0x80 {
            if n == max return s_ndup(s, i);
            n++;
        }
        i++;
    }
    s;
}

// Длина в единицах UTF-16, как её считает Telegram для лимитов подписей:
// символы за пределами BMP (эмодзи) занимают две единицы.
s_u16(s) {
    auto n;
    auto c;
    n = 0;
    while c = @8 *s {
        if (c & 0xC0) != 0x80 n++;
        if c >= 0xF0 n++;
        s++;
    }
    n;
}

// Сколько символов (не байт) в UTF-8 строке.
s_chars(s) {
    auto n;
    auto c;
    n = 0;
    while c = @8 *s {
        if (c & 0xC0) != 0x80 n++;
        s++;
    }
    n;
}

// Число из строки (0, если не число).
s_int(s) {
    if !s return 0;
    atoll(s);
}

// Строка в нижнем регистре: ASCII и кириллица (А–Я, Ё). Нужна для поиска и
// уникальности имён: lower() в БД зависит от локали и кириллицу может не знать.
s_lower(s) {
    auto n;
    auto d;
    auto i;
    auto j;
    auto c;
    auto c2;
    n = strlen(s);
    d = alloc(n + 1);
    i = 0;
    j = 0;
    while i < n {
        c = @8 *(s + i);
        c2 = 0;
        if i + 1 < n c2 = @8 *(s + i + 1);
        if (c >= 'A') & (c <= 'Z') {
            *(d + j) !8 c + 32;
            j++;
            i++;
        } else if (c == 0xD0) & (c2 >= 0x90) & (c2 <= 0x9F) {
            *(d + j) !8 0xD0;
            *(d + j + 1) !8 c2 + 0x20;
            j = j + 2;
            i = i + 2;
        } else if (c == 0xD0) & (c2 >= 0xA0) & (c2 <= 0xAF) {
            *(d + j) !8 0xD1;
            *(d + j + 1) !8 c2 - 0x20;
            j = j + 2;
            i = i + 2;
        } else if (c == 0xD0) & (c2 == 0x81) {
            *(d + j) !8 0xD1;
            *(d + j + 1) !8 0x91;
            j = j + 2;
            i = i + 2;
        } else {
            *(d + j) !8 c;
            j++;
            i++;
        }
    }
    *(d + j) !8 0;
    d;
}

// Хэштег из имени: буквы и цифры (ASCII и двухбайтовые вроде кириллицы), пробел,
// дефис и точка — в «_», остальное отбрасывается. Пустая строка, если букв нет.
s_tag(s) {
    auto n;
    auto d;
    auto i;
    auto j;
    auto c;
    auto letters;
    n = strlen(s);
    d = alloc(n + 2);
    i = 0;
    j = 0;
    letters = 0;
    while i < n {
        c = @8 *(s + i);
        if ((c >= 'a') & (c <= 'z')) | ((c >= 'A') & (c <= 'Z')) | ((c >= '0') & (c <= '9')) {
            *(d + j) !8 c;
            j++;
            letters++;
            i++;
        } else if (c >= 0xD0) & (c <= 0xDF) & (i + 1 < n) {
            *(d + j) !8 c;
            *(d + j + 1) !8 @8 *(s + i + 1);
            j = j + 2;
            letters++;
            i = i + 2;
        } else if (c == ' ') | (c == '-') | (c == '.') | (c == '_') {
            if (j > 0) & (@8 *(d + j - 1) != '_') {
                *(d + j) !8 '_';
                j++;
            }
            i++;
        } else if c >= 0xF0 i = i + 4;
        else if c >= 0xE0 i = i + 3;
        else if c >= 0xC0 i = i + 2;
        else i++;
    }
    if !letters return "";
    if @8 *(d + j - 1) == '_' j--;
    *(d + j) !8 0;
    d;
}

// Число в строку (id чатов отрицательные, поэтому со знаком).
s_itoa(n) {
    snprintf(&numbuf, 32, "%lld", n);
    s_dup(&numbuf);
}

// i-е поле строки, разделённой символом sep (с нуля); пустая строка, если полей меньше.
s_field(s, i, sep) {
    auto e;
    while i > 0 {
        e = strchr(s, sep);
        if !e return "";
        s = e + 1;
        i--;
    }
    e = strchr(s, sep);
    if e return s_ndup(s, e - s);
    s_dup(s);
}

// Список строк в одной строке: элементы разделены '\n', пустых нет.
l_count(s) {
    auto n;
    auto c;
    if @8 *s == 0 return 0;
    n = 1;
    while c = @8 *s {
        if c == '\n' n++;
        s++;
    }
    n;
}

l_get(s, i) {
    auto start;
    auto len;
    auto c;
    while (i > 0) & (@8 *s != 0) {
        if @8 *s == '\n' i--;
        s++;
    }
    start = s;
    len = 0;
    // & побитовый: в левой части должно быть 0 или 1, поэтому сравнение с нулём.
    while ((c = @8 *(start + len)) != 0) & (c != '\n') len++;
    s_ndup(start, len);
}

// Список без i-го элемента.
l_del(s, i) {
    auto b;
    auto k;
    auto n;
    b = sb_new();
    n = l_count(s);
    for k = 0 k < n k++ {
        if k != i {
            if sb_len(b) sb_c(b, '\n');
            sb_add(b, l_get(s, k));
        }
    }
    sb_str(b);
}

// Список через запятую.
l_join(s) {
    auto b;
    auto k;
    auto n;
    b = sb_new();
    n = l_count(s);
    for k = 0 k < n k++ {
        if k sb_add(b, ", ");
        sb_add(b, l_get(s, k));
    }
    sb_str(b);
}

l_add(s, item) {
    auto b;
    b = sb_new();
    sb_add(b, s);
    if sb_len(b) sb_c(b, '\n');
    sb_add(b, item);
    sb_str(b);
}

// Есть ли в списке элемент с таким же ключом (регистр не важен).
l_has(s, item) {
    auto k;
    auto n;
    auto key;
    key = s_lower(item);
    n = l_count(s);
    for k = 0 k < n k++ {
        if s_eq(s_lower(l_get(s, k)), key) return 1;
    }
    0;
}

// Имена из пользовательского текста: разделители «,», «;» и перевод строки; пустые и
// повторы отбрасываются, имя режется до 40 символов, всего не больше max имён.
// Результат — список в формате l_*.
s_names(raw, max) {
    auto res;
    auto part;
    auto start;
    auto i;
    auto c;
    auto name;
    res = "";
    start = 0;
    i = 0;
    while 1 {
        c = @8 *(raw + i);
        if (c == ',') | (c == ';') | (c == '\n') | (c == 0) {
            part = s_trim(s_ndup(raw + start, i - start));
            part = s_trim(s_cutc(part, 40));
            if (@8 *part != 0) & !l_has(res, part) & (l_count(res) < max) res = l_add(res, part);
            start = i + 1;
        }
        if c == 0 break;
        i++;
    }
    res;
}

// Строитель строки на арене: слова [0]=указатель, [8]=длина, [16]=ёмкость.
sb_new() {
    auto b;
    b = alloc(24);
    *b = alloc(256);
    *(b + 8) = 0;
    *(b + 16) = 256;
    *(*b) !8 0;
    b;
}

sb_grow(b, need) {
    auto cap;
    auto p;
    if *(b + 8) + need + 1 <= *(b + 16) return b;
    cap = *(b + 16) * 2;
    if cap < *(b + 8) + need + 1 cap = *(b + 8) + need + 1;
    p = alloc(cap);
    memcpy(p, *b, *(b + 8) + 1);
    *b = p;
    *(b + 16) = cap;
    b;
}

sb_addn(b, s, n) {
    sb_grow(b, n);
    memcpy(*b + *(b + 8), s, n);
    *(b + 8) = *(b + 8) + n;
    *(*b + *(b + 8)) !8 0;
    b;
}

sb_add(b, s) sb_addn(b, s, strlen(s));

sb_c(b, c) {
    sb_grow(b, 1);
    *(*b + *(b + 8)) !8 c;
    *(b + 8) = *(b + 8) + 1;
    *(*b + *(b + 8)) !8 0;
    b;
}

// Число со знаком (id чатов отрицательные).
sb_int(b, n) {
    snprintf(&numbuf, 32, "%lld", n);
    sb_add(b, &numbuf);
}

// Текст с экранированием для parse_mode=HTML; quote — экранировать и кавычки (для href).
sb_html(b, s, quote) {
    auto c;
    while c = @8 *s {
        if c == '&' sb_add(b, "&amp;");
        else if c == '<' sb_add(b, "&lt;");
        else if c == '>' sb_add(b, "&gt;");
        else if (c == '"') & quote sb_add(b, "&quot;");
        else sb_c(b, c);
        s++;
    }
    b;
}

sb_str(b) *b;

sb_len(b) *(b + 8);
