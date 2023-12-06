
.PHONY: build
build:
	docker-compose -f docker-compose.yml build web

.PHONY: up
up:
	make build
	docker-compose -f docker-compose.yml up -d web

.PHONY: down
down:
	docker-compose -f docker-compose.yml down

.PHONY: test
test:
	docker-compose -f docker-compose.yml build test
	docker-compose -f docker-compose.yml run   test prove -Ilib -r -v t
