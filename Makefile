.PHONY: up down build test lint migrate dev dev-backend dev-web dev-mobile brand brand-check help tidy

COMPOSE?=docker compose -f infra/docker-compose.yml --env-file .env
export PATH:=$(HOME)/.local/bin:$(PATH)
FLUTTER?=$(CURDIR)/.tooling/flutter/bin/flutter

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

## brand: Regenerate every frontend's branding from brand.json
brand:
	node scripts/brand-sync.mjs

## brand-check: Fail if any surface's branding drifted from brand.json
brand-check:
	node scripts/brand-sync.mjs --check

## tidy: go mod tidy
tidy:
	cd backend && go mod tidy

## test: brand drift check + Go tests + web build + flutter tests
test: brand-check
	cd backend && go test ./...
	cd frontend/web && pnpm build
	cd frontend/mobile && $(FLUTTER) analyze
	cd frontend/mobile && $(FLUTTER) test

## lint: go vet + eslint + flutter analyze
lint: brand-check
	cd backend && go vet ./...
	cd frontend/web && pnpm lint
	cd frontend/mobile && $(FLUTTER) analyze

## help: Show this help
help:
	@grep -E '^##' Makefile | sed 's/## //' | column -t -s ':'
