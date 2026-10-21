// Command seed creates one demo user per role so every API group can be
// exercised end-to-end. Development helper — run: go run ./cmd/seed
package main

import (
	"context"
	"fmt"
	"log"
	"os"

	"qaat/backend/internal/auth"
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

	// Ensure schema exists (seed may run before the server has started).
	migDir := findMigrations()
	if migDir != "" {
		if _, err := st.Migrate(context.Background(), migDir); err != nil {
			log.Fatalf("migrate: %v", err)
		}
	}

	type spec struct {
		email, name, reg, staff, role string
	}
	users := []spec{
		{"student@kiu.ac.ug", "Demo Student", "KIU3454S", "", "student"},
		{"lecturer@kiu.ac.ug", "Demo Lecturer", "", "KIU-0002", "lecturer"},
		{"qa@kiu.ac.ug", "Demo QA Staff", "", "KIU-0003", "qa_staff"},
		{"admin@kiu.ac.ug", "Demo Administrator", "", "KIU-0004", "administrator"},
		{"kiuadmin@kiu.ac.ug", "Demo KIU Admin", "", "KIU-0005", "kiu_admin"},
	}

	const password = "qaat-demo-1"
	hash, err := auth.HashPassword(password)
	if err != nil {
		log.Fatalf("hash: %v", err)
	}

	ctx := context.Background()
	for _, u := range users {
		// Skip if the email already exists (idempotent seed).
		if _, err := st.GetUserByEmail(ctx, u.email); err == nil {
			fmt.Printf("exists: %-24s (%s)\n", u.email, u.role)
			continue
		}
		id, err := st.CreateUser(ctx, u.email, u.email, hash, u.name, u.role, u.reg)
		if err != nil {
			log.Printf("create %s: %v", u.email, err)
			continue
		}
		if u.staff != "" {
			if _, err := st.DB.ExecContext(ctx,
				st.Q(`UPDATE users SET staff_number = ?, is_staff = TRUE WHERE id = ?`), u.staff, id); err != nil {
				log.Printf("set staff number %s: %v", u.email, err)
			}
		}
		fmt.Printf("created: %-24s (%s)\n", u.email, u.role)
	}
	fmt.Printf("\nAll demo users share password: %s\n", password)
}

// findMigrations walks up from the CWD looking for db/migrations.
func findMigrations() string {
	dir, err := os.Getwd()
	if err != nil {
		return ""
	}
	for i := 0; i < 6; i++ {
		if fi, err := os.Stat(dir + "/db/migrations"); err == nil && fi.IsDir() {
			return dir + "/db/migrations"
		}
		parent := dir + "/.."
		if dir == "/" {
			break
		}
		dir = parent
	}
	return ""
}
