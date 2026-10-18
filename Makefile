BIN    := build/tgbot
SRC    := src/bot.k
KIVAC  := .kiva/bin/kivac
KIVAA  := .kiva/bin/kivaa
LDLIBS := -lcurl -ljansson

.PHONY: all run test clean distclean
.DELETE_ON_ERROR:

all: $(BIN)

# Компилятор Kiva собирается один раз; kivaa появляется вместе с kivac.
$(KIVAC): scripts/setup-kiva.sh
	scripts/setup-kiva.sh

# kivaa не возвращает код ошибки nasm и cc, поэтому результат проверяется явно.
$(BIN): $(SRC) $(KIVAC)
	mkdir -p build
	rm -f $@
	$(KIVAC) $(SRC) build/tgbot.ir
	$(KIVAA) build/tgbot.ir $@ $(LDLIBS)
	test -x $@

run: $(BIN)
	@set -a; [ ! -f .env ] || . ./.env; set +a; exec $(BIN)

test: $(BIN)
	uv run --script tests/e2e.py $(BIN)

clean:
	rm -rf build

distclean: clean
	rm -rf .kiva
