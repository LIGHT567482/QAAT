.PHONY: up down build test lint migrate dev dev-backend dev-web dev-mobile help tidy

COMPOSE?=docker compose -f infra/docker-compose.yml --env-file .env
export PATH:=$(HOME)/.local/bin:$(PATH)
FLUTTER?=.tooling/flutter/bin/flutter

## up: Start Postgres + backend + web (dev stack)
up:
	@test -f .env || cp .env.example .env
	$(COMPOSE) up -d --build

## down: Stop the dev stack
down:
	$(COMPOSE) down

## build: Build backend + web images
build:
	$(COMPOSE) build

## logs: Tail all service logs
logs:
	$(COMPOSE) logs -f

## ps: Show running containers
ps:
	$(COMPOSE) ps

## migrate: Apply pending schema migrations (also runs automatically at backend startup)
migrate:
	cd backend && go run ./cmd/server
	@echo "Migrations applied. Server stopped if run in foreground — use 'make dev-backend'."

## dev-backend: Run the Go backend in the foreground (auto-migrates)
dev-backend:
	cd backend && QAAT_DATABASE_URL="$${QAAT_DATABASE_URL:-sqlite://qaat.db}" go run ./cmd/server

## seed: Create one demo user per role (password: qaat-demo-1)
seed:
	cd backend && QAAT_DATABASE_URL="$${QAAT_DATABASE_URL:-sqlite://qaat.db}" go run ./cmd/seed

## dev-web: Run the Next.js dashboards dev server
dev-web:
	cd frontend/web && pnpm dev

## dev-mobile: Run the Flutter app (choose a device with `flutter devices`)
dev-mobile:
	$(FLUTTER) run -d $(DEVICE) --dart-define=QAAT_API_URL=$${QAAT_API_URL:-http://localhost:8080}

## dev: Run backend + web together (Ctrl-C stops both)
dev:
	@$(MAKE) -s dev-backend & $(MAKE) -s dev-web; trap 'kill 0' EXIT INT TERM

## tidy: go mod tidy
tidy:
	cd backend && go mod tidy

## test: Backend Go tests + web typecheck/build + flutter tests
test:
	cd backend && go test ./...
	cd frontend/web && pnpm build
	-$(FLUTTER) analyze
	-$(FLUTTER) test

## lint: go vet + eslint + flutter analyze
lint:
	cd backend && go vet ./...
	cd frontend/web && pnpm lint
	-$(FLUTTER) analyze

## help: Show this help
help:
	@grep -E '^##' Makefile | sed 's/## //' | column -t -s ':'
