// Package auth implements QAAT authentication: bcrypt password hashing,
// JWT access tokens, role middleware, and the login-identifier resolution
// order fixed by spec doc 05 §2.
package auth

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"
	"github.com/golang-jwt/jwt/v5"
	"golang.org/x/crypto/bcrypt"
)

// Role is one of the five server role values (spec doc 05 §1). Roles are
// server-derived and never user-picked at runtime.
type Role string

const (
	RoleStudent      Role = "student"
	RoleLecturer     Role = "lecturer"
	RoleQAStaff      Role = "qa_staff"
	RoleAdministrator Role = "administrator"
	RoleKIUAdmin     Role = "kiu_admin"
)

// Valid reports whether r is one of the five roles.
func (r Role) Valid() bool {
	switch r {
	case RoleStudent, RoleLecturer, RoleQAStaff, RoleAdministrator, RoleKIUAdmin:
		return true
	}
	return false
}

// IsAdministrator: role ∈ {qa_staff, administrator, kiu_admin} (spec doc 05 §1).
func (r Role) IsAdministrator() bool {
	return r == RoleQAStaff || r == RoleAdministrator || r == RoleKIUAdmin
}

// HasLecturerAttendanceAccess: lecturer | kiu_admin (spec doc 05 §1).
func (r Role) HasLecturerAttendanceAccess() bool {
	return r == RoleLecturer || r == RoleKIUAdmin
}

// HasStaffOperationalAccess: qa_staff | administrator (spec doc 05 §1).
func (r Role) HasStaffOperationalAccess() bool {
	return r == RoleQAStaff || r == RoleAdministrator
}

// Claims is the JWT payload.
type Claims struct {
	UserID string `json:"uid"`
	Role   Role   `json:"role"`
	jwt.RegisteredClaims
}

// HashPassword bcrypt-hashes a plaintext password.
func HashPassword(plain string) (string, error) {
	b, err := bcrypt.GenerateFromPassword([]byte(plain), bcrypt.DefaultCost)
	return string(b), err
}

// CheckPassword compares plaintext against a bcrypt hash.
func CheckPassword(hash, plain string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(plain)) == nil
}

// IssueToken signs a short-TTL access token for a user (spec doc 05 §8).
func IssueToken(secret, userID string, role Role, ttl time.Duration) (string, error) {
	claims := Claims{
		UserID: userID,
		Role:   role,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID,
			ExpiresAt: jwt.NewNumericDate(time.Now().Add(ttl)),
			IssuedAt:  jwt.NewNumericDate(time.Now()),
			Issuer:    "qaat",
		},
	}
	return jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
}

// ParseToken validates a token string and returns its claims.
func ParseToken(secret, tokenStr string) (*Claims, error) {
	tok, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, errors.New("unexpected signing method")
		}
		return []byte(secret), nil
	})
	if err != nil {
		return nil, err
	}
	claims, ok := tok.Claims.(*Claims)
	if !ok || !tok.Valid {
		return nil, errors.New("invalid token")
	}
	return claims, nil
}

// bearer extracts the token from an Authorization header. Accepts both
// "Bearer <jwt>" and the legacy "Token <key>" form (spec doc 04 §1).
func bearer(h string) string {
	parts := strings.SplitN(h, " ", 2)
	if len(parts) != 2 {
		return ""
	}
	scheme := strings.ToLower(parts[0])
	if scheme != "bearer" && scheme != "token" {
		return ""
	}
	return strings.TrimSpace(parts[1])
}

const ctxUserKey = "qaat_user"

// User is the authenticated principal attached to the request context.
type User struct {
	ID   string
	Role Role
}

// Middleware validates the bearer token and injects the user into context.
// Missing/invalid token => 401 "Authentication credentials were not provided."
// (spec doc 04 §5). TODO(auth-merge): the store-backed /me lookup is layered on
// top by the API package; this middleware only authenticates the token.
func Middleware(secret string) gin.HandlerFunc {
	return func(c *gin.Context) {
		tok := bearer(c.GetHeader("Authorization"))
		if tok == "" {
			c.AbortWithStatusJSON(http.StatusUnauthorized,
				gin.H{"detail": "Authentication credentials were not provided."})
			return
		}
		claims, err := ParseToken(secret, tok)
		if err != nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized,
				gin.H{"detail": "Authentication credentials were not provided."})
			return
		}
		c.Set(ctxUserKey, User{ID: claims.UserID, Role: claims.Role})
		c.Next()
	}
}

// RequireRole aborts with 403 unless the caller's role is in allowed.
// Enforces the server-side permission matrix (spec doc 05 §3, gap #1/S1).
func RequireRole(allowed ...Role) gin.HandlerFunc {
	set := make(map[Role]bool, len(allowed))
	for _, r := range allowed {
		set[r] = true
	}
	return func(c *gin.Context) {
		u, ok := CurrentUser(c)
		if !ok {
			c.AbortWithStatusJSON(http.StatusUnauthorized,
				gin.H{"detail": "Authentication credentials were not provided."})
			return
		}
		if !set[u.Role] {
			c.AbortWithStatusJSON(http.StatusForbidden,
				gin.H{"detail": "You do not have permission to perform this action."})
			return
		}
		c.Next()
	}
}

// CurrentUser reads the authenticated user from context.
func CurrentUser(c *gin.Context) (User, bool) {
	v, ok := c.Get(ctxUserKey)
	if !ok {
		return User{}, false
	}
	u, ok := v.(User)
	return u, ok
}
