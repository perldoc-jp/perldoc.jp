
.PHONY: build
build:
	docker compose build

.PHONY: up
up:
	docker compose up -d app

.PHONY: down
down:
	docker compose down

.PHONY: test
test: TEST_TARGET = t
test:
	docker compose exec app prove -lrv $(TEST_TARGET)
