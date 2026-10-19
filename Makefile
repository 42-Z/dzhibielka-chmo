BIN    := build/tgbot
# Модулей в Kiva нет: перечисленные файлы склеиваются в один исходник.
SRCS   := src/core.k src/json.k src/db.k src/tg.k src/model.k src/post.k src/ui.k \
          src/wizard.k src/user.k src/admin.k src/inline.k src/main.k
GLUED  := build/bot.k
IR     := build/tgbot.ir
KIVAC  := .kiva/bin/kivac
KIVAA  := .kiva/bin/kivaa
LDLIBS := -lcurl -ljansson -lpq

.PHONY: all run test clean distclean
.DELETE_ON_ERROR:

all: $(BIN)

# Компилятор Kiva собирается один раз; kivaa появляется вместе с kivac.
$(KIVAC): scripts/setup-kiva.sh
	scripts/setup-kiva.sh

$(GLUED): $(SRCS)
	mkdir -p build
	cat $(SRCS) > $@

# kivaa не возвращает код ошибки nasm и cc, поэтому результат проверяется явно.
$(BIN): $(GLUED) $(KIVAC)
	rm -f $@
	$(KIVAC) $(GLUED) $(IR)
	$(KIVAA) $(IR) $@ $(LDLIBS)
	test -x $@

run: $(BIN)
	@scripts/run.sh $(BIN)

test: $(BIN)
	uv run --script tests/e2e.py $(BIN)

clean:
	rm -rf build

distclean: clean
	rm -rf .kiva
