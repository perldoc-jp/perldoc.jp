
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
# (data/recent.pl, data/years.pl, static/docs.json)。
.PHONY: setup-data
setup-data:
	docker compose exec app perl script/update.pl
	docker compose exec app perl script/create_recent.pl
	docker compose exec app sh -c 'perl script/create_year_data.pl $$(date +%Y)'
	docker compose exec app perl script/create_docs_json.pl

