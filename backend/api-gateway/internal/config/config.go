package config

import (
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"os"
	"strings"
)

type Config struct {
	Port              string
	DBURL             string
	AdminDBURL        string
	RedisURL          string
	AuthServiceURL    string
	SessionManagerURL string
	SyncReceiverURL   string
	NotificationURL   string
	CORSOrigins       []string
	JWT               JWTConfig
	LogLevel          string
	Env               string
	// keepalive warm loop — see internal/keepalive. Production (Render) sets
	// WarmEnabled so the gateway keeps itself and every sibling awake; local dev
	// leaves it off and nothing pings external prod services by accident.
	WarmEnabled         bool
	WarmIntervalSeconds int
	WarmSelfURL         string
	WarmSiblingURLs     []string
}

type JWTConfig struct {
	PublicKey *rsa.PublicKey
	Issuer    string
	Audience  string
}

func Load() (*Config, error) {
	pubKey, err := loadPublicKey(env("RSA_PUBLIC_KEY_PATH", "keys/auth_public.pem"))
	if err != nil {
		return nil, fmt.Errorf("load RSA public key: %w", err)
	}

	originsRaw := env("CORS_ORIGINS", "http://localhost:3000,http://localhost:3001")
	origins := strings.Split(originsRaw, ",")

	return &Config{
		Port: env("PORT", "8443"),
		// Tenant data plane: a NON-superuser, NON-owner role (qaat_app) so RLS is
		// actually enforced. See migration 009 / update.md C1.
		DBURL: mustEnv("DB_URL"),
		// Platform admin plane: a privileged connection used ONLY by the
		// ADMIN-RBAC-gated handlers (admin.go), which legitimately operate across
		// tenants (onboarding tenants, creating users).
		// Defaults to DB_URL if unset.
		AdminDBURL:        env("ADMIN_DB_URL", env("DB_URL", "")),
		RedisURL:          mustEnv("REDIS_URL"),
		AuthServiceURL:    env("AUTH_SERVICE_URL", "http://auth-service:8081"),
		SessionManagerURL: env("SESSION_MANAGER_URL", "http://session-manager:8082"),
		SyncReceiverURL:   env("SYNC_RECEIVER_URL", "http://sync-receiver:8083"),
		NotificationURL:   env("NOTIFICATION_URL", "http://notify:3004"),
		CORSOrigins:       origins,
		JWT: JWTConfig{
			PublicKey: pubKey,
			Issuer:    env("JWT_ISSUER", "qaat-auth"),
			Audience:  env("JWT_AUDIENCE", "qaat-api"),
		},
		LogLevel: env("LOG_LEVEL", "info"),
		Env:      env("ENVIRONMENT", "production"),
		// ─── keepalive warm loop ───────────────────────────────────────────────
		// Hand-rolled env parsing (not strconv helpers) keeps this file dependency-free.
		// Enabled only where WARM_ENABLED is set true — Render sets it in production;
		// local compose does not, so a dev instance never warms the real prod stack.
		WarmEnabled:         env("WARM_ENABLED", "") == "true",
		WarmIntervalSeconds: envInt("WARM_INTERVAL_SECONDS", 240),
		// The gateway's own public health URL. Self-pings are what keep the front door
		// from ever being the cold one, since every sibling is reached through it.
		WarmSelfURL: env("WARM_SELF_URL", ""),
		// Siblings are derived from the service URLs unless WARM_SIBLING_URLS is set.
		// Render reaches them by their public onrender.com URLs (declared in render.yaml);
		// the health path every one of them answers is /health.
		WarmSiblingURLs: warmSiblings(env("WARM_SIBLING_URLS", "")),
	}, nil
}

// warmSiblings builds the list of sibling health URLs to keep awake. An explicit
// WARM_SIBLING_URLS (comma-separated absolute URLs) wins outright; otherwise each
// configured sibling service URL gets /health appended, deduplicated. Used by the
// keepalive loop in main.
func warmSiblings(raw string) []string {
	if raw != "" {
		var out []string
		for _, s := range strings.Split(raw, ",") {
			if s = strings.TrimSpace(s); s != "" {
				out = append(out, s)
			}
		}
		return out
	}
	return nil
}

func envInt(key string, def int) int {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	n := 0
	for _, r := range v {
		if r < '0' || r > '9' {
			return def
		}
		n = n*10 + int(r-'0')
	}
	if n == 0 {
		return def
	}
	return n
}

func loadPublicKey(path string) (*rsa.PublicKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, fmt.Errorf("no PEM block in %s", path)
	}
	pub, err := x509.ParsePKIXPublicKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	rsaPub, ok := pub.(*rsa.PublicKey)
	if !ok {
		return nil, fmt.Errorf("not an RSA public key")
	}
	return rsaPub, nil
}

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		panic(fmt.Sprintf("required environment variable %s is not set", key))
	}
	return v
}
