// Package store provides persistence for QAAT. Development and CI run on
// SQLite (pure-Go driver, no cgo); production runs on PostgreSQL. The schema
// is dual-engine portable (spec doc 03) and applied by the migration runner.
package store

import (
	"context"
	"database/sql"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	_ "github.com/lib/pq"         // postgres driver (production)
	_ "modernc.org/sqlite"        // sqlite driver (dev/CI, no cgo)
)

// Store wraps the shared DB handle.
type Store struct {
	DB     *sql.DB
	driver string // "sqlite" | "postgres"
}

// now returns the current UTC time formatted for storage. Timestamps are
// stored as TEXT ISO-8601 UTC (dual-engine portable, spec doc 03 §1).
func now() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05.000Z")
}

// Open connects to the database implied by the URL and pings it.
func Open(databaseURL string) (*Store, error) {
	driver, dsn, err := parseURL(databaseURL)
	if err != nil {
		return nil, err
	}
	db, err := sql.Open(driver, dsn)
	if err != nil {
		return nil, fmt.Errorf("open db: %w", err)
	}
	if driver == "sqlite" {
		// Reasonable SQLite concurrency for dev.
		db.SetMaxOpenConns(1)
	}
	if err := db.Ping(); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("ping db: %w", err)
	}
	return &Store{DB: db, driver: driver}, nil
}

// parseURL maps a QAAT database URL onto a driver + DSN.
func parseURL(u string) (driver, dsn string, err error) {
	switch {
	case u == "" || strings.HasPrefix(u, "sqlite://:memory:") || u == ":memory:":
		return "sqlite", "file:qaat?mode=memory&cache=shared", nil
	case strings.HasPrefix(u, "sqlite://"):
		return "sqlite", strings.TrimPrefix(u, "sqlite://"), nil
	case strings.HasPrefix(u, "postgres://"), strings.HasPrefix(u, "postgresql://"):
		return "postgres", u, nil
	default:
		return "", "", fmt.Errorf("unsupported database URL %q", u)
	}
}

// Close releases the underlying handle.
func (s *Store) Close() error { return s.DB.Close() }

// Migrate applies every pending .sql file in dir in filename order, tracking
// applied files in schema_migrations. Each file runs in its own transaction;
// migration files must not contain BEGIN/COMMIT (repo convention).
func (s *Store) Migrate(ctx context.Context, dir string) ([]string, error) {
	if _, err := s.DB.ExecContext(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version TEXT PRIMARY KEY,
		applied_at TEXT NOT NULL
	)`); err != nil {
		return nil, fmt.Errorf("create schema_migrations: %w", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read migrations dir: %w", err)
	}
	var files []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".sql") {
			files = append(files, e.Name())
		}
	}
	sort.Strings(files)

	var applied []string
	for _, name := range files {
		var exists int
		err := s.DB.QueryRowContext(ctx,
			`SELECT COUNT(1) FROM schema_migrations WHERE version = ?`, name).Scan(&exists)
		if err != nil {
			// Postgres uses $1 placeholders; retry with that form.
			err = s.DB.QueryRowContext(ctx,
				`SELECT COUNT(1) FROM schema_migrations WHERE version = $1`, name).Scan(&exists)
		}
		if err != nil {
			return applied, fmt.Errorf("check migration %s: %w", name, err)
		}
		if exists > 0 {
			continue
		}

		body, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return applied, fmt.Errorf("read migration %s: %w", name, err)
		}
		if err := s.applyOne(ctx, name, string(body)); err != nil {
			return applied, fmt.Errorf("apply migration %s: %w", name, err)
		}
		applied = append(applied, name)
	}
	return applied, nil
}

func (s *Store) applyOne(ctx context.Context, version, body string) error {
	tx, err := s.DB.BeginTx(ctx, nil)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()
	if _, err := tx.ExecContext(ctx, body); err != nil {
		return err
	}
	q := `INSERT INTO schema_migrations (version, applied_at) VALUES (?, ?)`
	if s.driver == "postgres" {
		q = `INSERT INTO schema_migrations (version, applied_at) VALUES ($1, $2)`
	}
	if _, err := tx.ExecContext(ctx, q, version, now()); err != nil {
		return err
	}
	return tx.Commit()
}
