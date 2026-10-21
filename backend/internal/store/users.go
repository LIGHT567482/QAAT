package store

import (
	"context"
	"database/sql"
	"errors"
	"strings"

	"github.com/google/uuid"
)

// ErrNotFound is returned when a lookup matches no row.
var ErrNotFound = errors.New("not found")

// User is the persisted identity row (spec doc 03 §2.1).
type User struct {
	ID                string
	Username          string
	Email             string
	PasswordHash      string
	FullName          string
	Role              string
	RegistrationNumber sql.NullString
	StaffNumber       sql.NullString
	EmailVerified     bool
	IsActive          bool
}

// Public returns the API projection of a user (no secrets).
func (u User) Public() map[string]any {
	m := map[string]any{
		"id":            u.ID,
		"username":      u.Username,
		"email":         u.Email,
		"fullName":      u.FullName,
		"role":          u.Role,
		"emailVerified": u.EmailVerified,
		"isActive":      u.IsActive,
	}
	if u.RegistrationNumber.Valid {
		m["registrationNumber"] = u.RegistrationNumber.String
	}
	if u.StaffNumber.Valid {
		m["staffNumber"] = u.StaffNumber.String
	}
	return m
}

func (s *Store) q(query string) string {
	if s.driver == "postgres" {
		// Convert ? placeholders to $1..$n for postgres.
		var b strings.Builder
		n := 0
		for _, r := range query {
			if r == '?' {
				n++
				b.WriteString("$")
				b.WriteString(itoa(n))
			} else {
				b.WriteRune(r)
			}
		}
		return b.String()
	}
	return query
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var digits []byte
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}

// CreateUser inserts a new user row and returns its generated id. An optional
// registration number is stored for students (spec doc 03 §2.1) so login can
// resolve it (spec doc 05 §2 step 2).
func (s *Store) CreateUser(ctx context.Context, username, email, passwordHash, fullName, role string, regNumber string) (string, error) {
	id := uuid.NewString()
	var reg any
	if regNumber != "" {
		reg = regNumber
	}
	_, err := s.DB.ExecContext(ctx, s.q(`
		INSERT INTO users (id, username, email, password_hash, full_name, role, registration_number, created_at, updated_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`),
		id, username, email, passwordHash, fullName, role, reg, now(), now())
	if err != nil {
		return "", err
	}
	return id, nil
}

// GetUserByID fetches a user by id.
func (s *Store) GetUserByID(ctx context.Context, id string) (User, error) {
	return s.scanUser(s.DB.QueryRowContext(ctx, s.q(`
		SELECT id, username, email, password_hash, full_name, role,
		       registration_number, staff_number, email_verified, is_active
		FROM users WHERE id = ?`), id))
}

// GetUserByEmail fetches a user by case-insensitive email.
func (s *Store) GetUserByEmail(ctx context.Context, email string) (User, error) {
	return s.scanUser(s.DB.QueryRowContext(ctx, s.q(`
		SELECT id, username, email, password_hash, full_name, role,
		       registration_number, staff_number, email_verified, is_active
		FROM users WHERE LOWER(email) = LOWER(?)`), email))
}

// GetUserByRegistrationNumber fetches a user by exact registration number.
func (s *Store) GetUserByRegistrationNumber(ctx context.Context, reg string) (User, error) {
	return s.scanUser(s.DB.QueryRowContext(ctx, s.q(`
		SELECT id, username, email, password_hash, full_name, role,
		       registration_number, staff_number, email_verified, is_active
		FROM users WHERE registration_number = ?`), reg))
}

// GetUserByStaffNumber fetches a user by canonical staff number.
func (s *Store) GetUserByStaffNumber(ctx context.Context, staff string) (User, error) {
	return s.scanUser(s.DB.QueryRowContext(ctx, s.q(`
		SELECT id, username, email, password_hash, full_name, role,
		       registration_number, staff_number, email_verified, is_active
		FROM users WHERE staff_number = ?`), staff))
}

func (s *Store) scanUser(row *sql.Row) (User, error) {
	var u User
	err := row.Scan(&u.ID, &u.Username, &u.Email, &u.PasswordHash, &u.FullName,
		&u.Role, &u.RegistrationNumber, &u.StaffNumber, &u.EmailVerified, &u.IsActive)
	if errors.Is(err, sql.ErrNoRows) {
		return User{}, ErrNotFound
	}
	return u, err
}

// SetEmailVerified marks a user's email as verified.
func (s *Store) SetEmailVerified(ctx context.Context, userID string) error {
	_, err := s.DB.ExecContext(ctx, s.q(`
		UPDATE users SET email_verified = ?, updated_at = ? WHERE id = ?`),
		true, now(), userID)
	return err
}

// SetPassword updates a user's password hash.
func (s *Store) SetPassword(ctx context.Context, userID, hash string) error {
	_, err := s.DB.ExecContext(ctx, s.q(`
		UPDATE users SET password_hash = ?, updated_at = ? WHERE id = ?`),
		hash, now(), userID)
	return err
}
