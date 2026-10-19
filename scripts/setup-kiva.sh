#!/usr/bin/env bash
# Собирает компилятор Kiva (kivac + kivaa) из закреплённого коммита в .kiva/bin.
# Права root не нужны. Повторный запуск пересобирает всё с нуля.
#
# Сборка по README Kiva: kivaa (C) превращает bootstrap/kiva.ir в первый kivac,
# тот компилирует kiva.k, и затем проверяется неподвижная точка: готовый kivac
# должен воспроизвести собственный IR.
set -euo pipefail

REPO_URL=https://github.com/crimbrodev/kivac-plus.git
REV=60ca86910c72bc6ca561aba498df18196bf93903

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
kiva=$(dirname "$here")/.kiva
src=$kiva/src
stage=$kiva/stage
bin=$kiva/bin
log=$kiva/setup.log

die() {
    echo "setup-kiva: $*" >&2
    exit 1
}

for tool in git cc nasm cmp; do
    command -v "$tool" >/dev/null || die "не найден '$tool' (нужны git, cc, nasm)"
done

mkdir -p "$kiva"
: >"$log"

# Запускает команду, а при ошибке показывает накопленный stderr.
run() {
    "$@" 2>>"$log" || {
        cat "$log" >&2
        die "ошибка: $*"
    }
}

# kivaa не передаёт коды возврата nasm и cc, поэтому проверяем результат сами.
assemble() {
    local ir=$1 out=$2
    rm -f "$out"
    run "$bin/kivaa" "$ir" "$out"
    [ -x "$out" ] || {
        cat "$log" >&2
        die "kivaa не создал $out"
    }
}

[ -d "$src/.git" ] || run git clone --quiet "$REPO_URL" "$src"
run git -C "$src" checkout --quiet --detach "$REV"

# Бот держит в исходнике около 18 КБ строковых литералов. Компилятор складывает их в
# один буфер strbuf[N] (N слов по 8 байт), а при переполнении молча портит свою память,
# поэтому слишком маленький буфер лучше обнаружить до пересборки: рабочий компилятор
# в .kiva/bin при этом не трогаем.
need_words=8192  # 64 КБ
have_words=$(sed -n 's/^strbuf\[\([0-9]*\)\];.*/\1/p' "$src/kiva.k")
[ "${have_words:-0}" -ge "$need_words" ] ||
    die "в $REV буфер строковых литералов — ${have_words:-?} слов, боту нужно не меньше $need_words; укажите REV из kivac-plus с увеличенным strbuf"

rm -rf "$stage" "$bin"
mkdir -p "$stage" "$bin"

echo "Kiva $REV: сборка компилятора"
run cc -o "$bin/kivaa" "$src/kivaa.c"

assemble "$src/bootstrap/kiva.ir" "$stage/kivac0"
run "$stage/kivac0" "$src/kiva.k" "$stage/kivac1.ir"
assemble "$stage/kivac1.ir" "$stage/kivac"

run "$stage/kivac" "$src/kiva.k" "$stage/kivac2.ir"
cmp -s "$stage/kivac1.ir" "$stage/kivac2.ir" ||
    die "компилятор не воспроизводит сам себя: bootstrap/kiva.ir не соответствует kiva.k"

cp "$stage/kivac" "$bin/kivac"
echo "Готово: $bin/kivac, $bin/kivaa"
