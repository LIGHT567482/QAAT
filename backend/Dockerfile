# QAAT backend — one Go (Gin) service exposing the per-role API groups.
# Build context MUST be the repo root (see infra/docker-compose.yml) so the
# fresh-schema migrations in db/ are available.
FROM golang:1.27-alpine AS build
WORKDIR /src
COPY backend/go.mod backend/go.sum ./
RUN go mod download
COPY backend/ .
RUN CGO_ENABLED=0 go build -o /out/qaat-api ./cmd/server

FROM alpine:3.20
WORKDIR /app/backend
COPY --from=build /out/qaat-api /usr/local/bin/qaat-api
# main walks up from CWD for db/migrations -> /app/db/migrations.
COPY db/migrations /app/db/migrations
EXPOSE 8080
ENTRYPOINT ["qaat-api"]
