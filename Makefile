BIN    := build/tgbot
# Модулей в Kiva нет: перечисленные файлы склеиваются в один исходник.
SRCS   := src/core.k src/json.k src/db.k src/tg.k src/model.k src/post.k src/ui.k \
          src/wizard.k src/nav.k src/user.k src/admin.k src/inline.k src/main.k
GLUED  := build/bot.k
IR     := build/tgbot.ir
KIVAC  := .kiva/bin/kivac
KIVAA  := .kiva/bin/kivaa
LDLIBS := -lcurl -ljansson -lpq

.PHONY: all run test banners avatar clean distclean
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

# Перерисовывает баннеры из assets/make_banners.py (стиль — assets/STYLE.md).
banners:
	uv run --script assets/make_banners.py

# Рисует аватарку бота: assets/avatar.jpg (её ставят через @BotFather /setuserpic или Bot API setMyProfilePhoto).
avatar:
	uv run --script assets/make_avatar.py

clean:
	rm -rf build

distclean: clean
	rm -rf .kiva
