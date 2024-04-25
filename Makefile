
.PHONY: build
build:
	docker compose build dev

.PHONY: up
up:
	make build
	docker compose up -d dev

.PHONY: down
down:
	docker compose down

.PHONY: test
test: TEST_TARGET = t
test: docker compose exec dev prove -lrv $(TEST_TARGET)
