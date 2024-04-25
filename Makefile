
.PHONY: build
build:
	docker compose build

.PHONY: up
up:
	docker compose up -d

.PHONY: down
down:
	docker compose down

.PHONY: test
test: TEST_TARGET = t
test: docker compose exec dev prove -lrv $(TEST_TARGET)
