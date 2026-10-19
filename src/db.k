// db.k: Postgres через libpq.
//
// PQexecParams и PQexecPrepared принимают больше шести аргументов, а такие вызовы
// Kiva передаёт неверно. Поэтому запросы собираются строкой, а каждое значение
// проходит через PQescapeLiteral (sb_lit); числа вставляются как есть (sb_int).
//
// Результат последнего запроса хранится в db_res и освобождается следующим
// db_exec, поэтому строки из db_val нужно копировать (s_dup), если они нужны
// после очередного запроса, а идентификаторы строк результата — прочитать до
// запросов внутри цикла.

db_conn;     // соединение
db_res;      // результат последнего запроса
db_in_tx;    // внутри транзакции: тогда повторять запрос после обрыва связи нельзя

db_connect(url) {
    db_conn = PQconnectdb(url);
    if (PQstatus(db_conn) & 0xFFFFFFFF) != 0 {
        fprintf(stderr, "БД: %s", PQerrorMessage(db_conn));
        return 0;
    }
    db_exec("SET client_min_messages TO WARNING");  // без NOTICE от IF NOT EXISTS
    1;
}

db_clear() {
    if db_res {
        PQclear(db_res);
        db_res = 0;
    }
    0;
}

// Выполняет запрос один раз; истина для PGRES_COMMAND_OK (1) и PGRES_TUPLES_OK (2).
db_run(sql) {
    auto st;
    db_clear();
    db_res = PQexec(db_conn, sql);
    if !db_res return 0;
    st = PQresultStatus(db_res) & 0xFFFFFFFF;
    (st == 1) | (st == 2);
}

// Выполняет SQL; при обрыве связи вне транзакции переподключается и повторяет один раз.
db_exec(sql) {
    if db_run(sql) return 1;
    if !db_in_tx & ((PQstatus(db_conn) & 0xFFFFFFFF) != 0) {
        PQreset(db_conn);
        if db_run(sql) return 1;
    }
    if db_res fprintf(stderr, "БД: %s", PQresultErrorMessage(db_res));
    else fprintf(stderr, "БД: %s", PQerrorMessage(db_conn));
    0;
}

db_rows() PQntuples(db_res) & 0xFFFFFFFF;

// Значение ячейки как строка; для NULL — пустая строка.
db_val(r, c) PQgetvalue(db_res, r, c);

db_int(r, c) atoll(PQgetvalue(db_res, r, c));

db_null(r, c) PQgetisnull(db_res, r, c) & 0xFFFFFFFF;

// Сколько строк затронул последний INSERT/UPDATE/DELETE.
db_changed() atoll(PQcmdTuples(db_res));

// Значение SQL-строкой в кавычках, безопасной для вставки в запрос.
db_lit(s) {
    auto e;
    auto r;
    e = PQescapeLiteral(db_conn, s, strlen(s));
    if !e {
        fprintf(stderr, "БД: %s", PQerrorMessage(db_conn));
        return "''";
    }
    r = s_dup(e);
    PQfreemem(e);
    r;
}

sb_lit(b, s) sb_add(b, db_lit(s));

db_begin() {
    if !db_exec("BEGIN") return 0;
    db_in_tx = 1;
    1;
}

// Флаг db_in_tx снимается после запроса: при обрыве связи COMMIT на новом
// соединении «прошёл бы» без данных, поэтому повторять его нельзя.
db_commit() {
    auto ok;
    ok = db_exec("COMMIT");
    db_in_tx = 0;
    ok;
}

db_rollback() {
    auto ok;
    ok = db_exec("ROLLBACK");
    db_in_tx = 0;
    ok;
}

// Применяет файл схемы (CREATE ... IF NOT EXISTS): можно запускать при каждом старте.
db_schema(path) {
    auto sql;
    sql = read_file(path);
    if !sql {
        fprintf(stderr, "Не найден файл схемы БД: %s\n", path);
        return 0;
    }
    db_exec(sql);
}
