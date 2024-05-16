
.PHONY: build
build:
	docker compose build

.PHONY: up
up:
	docker compose up

.PHONY: down
down:
	docker compose down

.PHONY: test
test: TEST_TARGET = t
test:
	docker compose exec app prove -lrv $(TEST_TARGET)

.PHONY: ci
ci:
	docker compose up -d
	make setup-data
	make test

# 翻訳データのセットアップ
# TODO: 翻訳データのセットアップは他にもあるので、全部ひとまとめにできると良さそう
.PHONY: setup-data
setup-data:
	docker compose exec app perl script/update.pl

