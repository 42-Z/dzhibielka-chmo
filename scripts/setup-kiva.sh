#!/usr/bin/env bash
# Собирает компилятор Kiva (kivac + kivaa) из закреплённого коммита в .kiva/bin.
# Права root не нужны. Повторный запуск пересобирает всё с нуля.
#
# Сборка по README Kiva: kivaa (C) превращает bootstrap/kiva.ir в первый kivac,
# тот компилирует kiva.k, и затем проверяется неподвижная точка: готовый kivac
# должен воспроизвести собственный IR.
set -euo pipefail

REPO_URL=https://github.com/crimbrodev/kivac.git
REV=221280b7f6dede3d51e5485a8a35c91a70dc65bb

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

rm -rf "$stage" "$bin"
mkdir -p "$stage" "$bin"
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
