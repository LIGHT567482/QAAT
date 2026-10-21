package config

import (
	"os"
	"strconv"
)

// Config holds runtime configuration resolved from the environment.
type Config struct {
	// Addr is the listen address, e.g. ":8080".
	Addr string
	// DatabaseURL selects the engine. "sqlite:///path.db" (dev default) or
	// "postgres://..." (production). Empty => in-memory SQLite.
	DatabaseURL string
	// JWTSecret signs access tokens. Must be set in production.
	JWTSecret string
	// AccessTokenTTL is the access-token lifetime (spec doc 05 §8: short TTL + refresh).
	AccessTokenTTLSeconds int
	// PublicAPIURL is used in email links (verify / reset).
	PublicAPIURL string
	// APPReturnURL is the mobile deep link target after email verify.
	APPReturnURL string
	// Env is "dev", "test", or "prod".
	Env string
}

// Load reads configuration from environment variables with dev-safe defaults.
func Load() Config {
	return Config{
		Addr:                  getenv("QAAT_ADDR", ":8080"),
		DatabaseURL:           getenv("QAAT_DATABASE_URL", "sqlite://:memory:"),
		JWTSecret:             getenv("QAAT_JWT_SECRET", "dev-insecure-secret-change-me"),
		AccessTokenTTLSeconds: getenvInt("QAAT_ACCESS_TTL_SECONDS", 7200), // 2h
		PublicAPIURL:          getenv("QAAT_PUBLIC_API_URL", "http://localhost:8080"),
		APPReturnURL:          getenv("QAAT_APP_RETURN_URL", "qaat://open/email-verified"),
		Env:                   getenv("QAAT_ENV", "dev"),
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getenvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}
