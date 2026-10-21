// Command server runs the QAAT backend: one Go (Gin) service exposing the
// per-role API groups. Attendance endpoints are 501 stubs until the engine
// merges in (spec doc 06).
package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"qaat/backend/internal/api"
	"qaat/backend/internal/config"
	"qaat/backend/internal/store"
)

func main() {
	cfg := config.Load()

	st, err := store.Open(cfg.DatabaseURL)
	if err != nil {
		log.Fatalf("db open: %v", err)
	}
	defer st.Close()

	// Apply fresh-schema migrations (spec doc 03). Locate db/migrations by
	// walking up from the working directory.
	migDir := findMigrations()
	if migDir != "" {
		applied, err := st.Migrate(context.Background(), migDir)
		if err != nil {
			log.Fatalf("migrate: %v", err)
		}
		for _, m := range applied {
			log.Printf("applied migration %s", m)
		}
	} else {
		log.Printf("no db/migrations found — skipping schema apply")
	}

	h := &api.Handlers{Cfg: cfg, Store: st}
	r := api.NewRouter(h)

	go func() {
		if err := r.Run(cfg.Addr); err != nil {
			log.Fatalf("listen: %v", err)
		}
	}()
	log.Printf("qaat-api listening on %s", cfg.Addr)

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit
	log.Println("shutting down...")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = st.DB.Close()
	<-ctx.Done()
}

// findMigrations walks up from the CWD looking for db/migrations.
func findMigrations() string {
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for i := 0; i < 6; i++ {
		cand := filepath.Join(dir, "db", "migrations")
		if fi, err := os.Stat(cand); err == nil && fi.IsDir() {
			return cand
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return ""
}
