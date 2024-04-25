
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
	docker compose run --rm app prove -lrv $(TEST_TARGET)
