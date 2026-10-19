// json.k: удобные обёртки над jansson.
//
// Запросы к Bot API строятся как дерево jansson и целиком уходят в tg_post.
// Функции jset*/jpush возвращают сам контейнер, поэтому вызовы можно вкладывать.
// json_object_set_new и json_array_append_new забирают ссылку на значение; NULL
// (например, json_string от некорректного UTF-8) они принимают и просто
// возвращают ошибку, поле остаётся незаданным. Корень освобождается через
// json_release. Строки, взятые из разобранного ответа (jstr), принадлежат корню и
// живут до его освобождения.

jo() json_object();

ja() json_array();

jset(o, k, v) {
    json_object_set_new(o, k, v);
    o;
}

jsets(o, k, s) {
    json_object_set_new(o, k, json_string(s));
    o;
}

jseti(o, k, n) {
    json_object_set_new(o, k, json_integer(n));
    o;
}

jsetb(o, k, b) {
    if b json_object_set_new(o, k, json_true());
    else json_object_set_new(o, k, json_false());
    o;
}

jpush(a, v) {
    json_array_append_new(a, v);
    a;
}

// Независимая копия дерева: клавиатуру, которую отдают в tg_post (он её съедает),
// нужно скопировать заранее, если запрос могут повторить.
jcopy(v) json_deep_copy(v);

jget(o, k) json_object_get(o, k);

// Строка поля или 0, если поля нет или оно не строка.
jstr(o, k) json_string_value(json_object_get(o, k));

jint(o, k) json_integer_value(json_object_get(o, k));

// Истина, если поле есть и равно true.
jtrue(o, k) json_equal(json_object_get(o, k), json_true()) & 0xFFFFFFFF;

// Освобождает корень дерева jansson (можно передать 0). json_decref в jansson.h
// объявлен inline и в библиотеке не экспортируется; для единственной ссылки
// он сводится к json_delete.
json_release(root)
    if root json_delete(root);

// JSON-текст дерева на арене (0, если сериализовать не удалось).
jdump(root) {
    auto raw;
    auto s;
    raw = json_dumps(root, 0x20);  // JSON_COMPACT
    if !raw return 0;
    s = s_dup(raw);
    free(raw);
    s;
}
