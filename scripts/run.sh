#!/usr/bin/env bash
# Запускает бота с переменными из .env (путь можно задать через ENV_FILE).
#
# Файл читается как dotenv, а не как shell-скрипт: «&» в строке подключения
# (?sslmode=require&channel_binding=require) не запускает фоновую команду, значения
# не раскрываются. Пара внешних кавычек у значения снимается, как в docker compose.
set -euo pipefail

bin=${1:?использование: run.sh <бинарник бота>}
env_file=${ENV_FILE:-.env}

die() {
    echo "run: $*" >&2
    exit 1
}

if [ -f "$env_file" ]; then
    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        line=${line%$'\r'}
        line=${line#"${line%%[![:space:]]*}"}  # пробелы в начале
        case $line in
            '' | '#'*) continue ;;
        esac
        line=${line#export }
        key=${line%%=*}
        key=${key%"${key##*[![:space:]]}"}  # пробелы перед «=»
        [[ $line == *=* && $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] ||
            die "$env_file:$n: ожидается строка вида ИМЯ=значение"
        val=${line#*=}
        val=${val#"${val%%[![:space:]]*}"}
        val=${val%"${val##*[![:space:]]}"}
        case $val in
            \"*\" | \'*\') val=${val:1:${#val}-2} ;;
        esac
        export "$key=$val"
    done <"$env_file"
fi

exec "$bin"
