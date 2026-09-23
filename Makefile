
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

# 翻訳データと、それに依存する生成物のセットアップ。
# 本番の Dockerfile databuild ステージと同じ生成物を作る
# (data/recent.pl, static/docs.json,
#  data/index-module.pl, data/index-article.pl)。
# data/years.pl は databuild でも作らない (ビルドより前に
# script/update-years.pl が再導出してコミットする)。手元で更新したい場合は
# docker compose exec app perl script/update-years.pl を別途実行する。
.PHONY: setup-data
setup-data:
	docker compose exec app perl script/update.pl
	docker compose exec app perl script/create_data.pl

