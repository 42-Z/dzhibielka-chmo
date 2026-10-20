BIN    := build/tgbot
# Тестовая сборка повторяет обычную, но с адресом поддельного Bot API. Её запускает
# tests/e2e.py: порт локального сервера известен только во время работы теста.
TEST_BIN  := build/tgbot-test
TEST_GLUE := build/bot-test.k
TEST_IR   := build/tgbot-test.ir
# Модулей в Kiva нет: перечисленные файлы склеиваются в один исходник.
SRCS   := src/core.k src/json.k src/db.k src/tg.k src/model.k src/post.k src/ui.k \
          src/wizard.k src/nav.k src/user.k src/admin.k src/inline.k src/main.k
GLUED  := build/bot.k
IR     := build/tgbot.ir
KIVAC  := .kiva/bin/kivac
KIVAA  := .kiva/bin/kivaa
LDLIBS := -lcurl -ljansson -lpq

.PHONY: all run test banners avatar clean distclean $(TEST_BIN)
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

# Объявлена фиктивной: адрес (порт) теста меняется от запуска к запуску, поэтому
# исходник с подменённой строкой пересобирается всегда.
$(TEST_BIN): $(SRCS) $(KIVAC)
	mkdir -p build
	: "${API_URL:?адрес поддельного Bot API передаёт tests/e2e.py}"
	cat $(SRCS) | sed 's|https://api.telegram.org|$(API_URL)|g' > $(TEST_GLUE)
	$(KIVAC) $(TEST_GLUE) $(TEST_IR)
	$(KIVAA) $(TEST_IR) $@ $(LDLIBS)
	test -x $@

run: $(BIN)
	@scripts/run.sh $(BIN)

test: $(BIN)
	uv run --script tests/e2e.py

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
