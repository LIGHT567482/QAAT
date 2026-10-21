// Package api wires the QAAT HTTP surface: /health, /api/auth/*, and the
// per-role groups /api/student, /api/lecturer, /api/admin. Attendance
// endpoints under each group are routed and role-guarded but return 501 until
// the attendance merge lands (spec doc 06).
package api

import (
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"qaat/backend/internal/auth"
	"qaat/backend/internal/config"
	"qaat/backend/internal/store"
)

// Handlers holds shared dependencies for the HTTP layer.
type Handlers struct {
	Cfg   config.Config
	Store *store.Store
}

// NewRouter builds the Gin engine with every route registered.
func NewRouter(h *Handlers) *gin.Engine {
	if h.Cfg.Env == "prod" {
		gin.SetMode(gin.ReleaseMode)
	}
	r := gin.New()
	r.Use(gin.Logger(), gin.Recovery())

	// Public health + descriptor (spec doc 04 §1).
	r.GET("/health", h.health)
	r.GET("/api/health", h.health)
	r.GET("/api", h.descriptor)

	// Auth group (spec doc 04 §2).
	ag := r.Group("/api/auth")
	ag.POST("/login", h.login)
	ag.POST("/register", h.register)
	ag.GET("/me", auth.Middleware(h.Cfg.JWTSecret), h.me)
	ag.PATCH("/me", auth.Middleware(h.Cfg.JWTSecret), h.updateMe)

	// Per-role API groups. Attendance sub-routes are the merge slot.
	//
	// No /dashboard for students: spec doc 07 gives students the Attendance ·
	// Notices · Profile surface, not a dashboard — the group below is
	// attendance-only until the notices API lands.
	student := r.Group("/api/student", auth.Middleware(h.Cfg.JWTSecret),
		auth.RequireRole(auth.RoleStudent))
	registerAttendanceRoutes(student, auth.RoleStudent)

	lecturer := r.Group("/api/lecturer", auth.Middleware(h.Cfg.JWTSecret),
		auth.RequireRole(auth.RoleLecturer, auth.RoleKIUAdmin))
	lecturer.GET("/dashboard", h.lecturerDashboard)
	registerAttendanceRoutes(lecturer, auth.RoleLecturer)

	admin := r.Group("/api/admin", auth.Middleware(h.Cfg.JWTSecret),
		auth.RequireRole(auth.RoleQAStaff, auth.RoleAdministrator, auth.RoleKIUAdmin))
	admin.GET("/dashboard", h.adminDashboard)

	return r
}

func (h *Handlers) health(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{"status": "ok", "service": "qaat-api"})
}

func (h *Handlers) descriptor(c *gin.Context) {
	c.JSON(http.StatusOK, gin.H{
		"name":    "qaat",
		"version": "1.0.0",
		"docs":    "docs/qaat-spec/README.md",
	})
}

// login authenticates via the identifier resolution order (spec doc 05 §2).
func (h *Handlers) login(c *gin.Context) {
	var req struct {
		Login    string `json:"login"`
		Password string `json:"password"`
	}
	if err := c.ShouldBindJSON(&req); err != nil || req.Login == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Malformed request."})
		return
	}

	user, err := h.resolveIdentifier(c, req.Login)
	if err != nil || !auth.CheckPassword(user.PasswordHash, req.Password) || !user.IsActive {
		// Fixed 401 — no user enumeration (spec doc 05 §2).
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Wrong email or password."})
		return
	}

	ttl := time.Duration(h.Cfg.AccessTokenTTLSeconds) * time.Second
	token, err := auth.IssueToken(h.Cfg.JWTSecret, user.ID, auth.Role(user.Role), ttl)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Could not issue token."})
		return
	}
	c.JSON(http.StatusOK, gin.H{"token": token, "user": user.Public()})
}

// resolveIdentifier walks email → reg no → staff number → synthetic email →
// admin pattern (spec doc 05 §2).
func (h *Handlers) resolveIdentifier(c *gin.Context, ident string) (store.User, error) {
	// 1. Email (case-insensitive).
	if u, err := h.Store.GetUserByEmail(c.Request.Context(), ident); err == nil {
		return u, nil
	}
	// 2. Registration number.
	if u, err := h.Store.GetUserByRegistrationNumber(c.Request.Context(), strings.ToUpper(ident)); err == nil {
		return u, nil
	}
	// 3/4. Staff number, including the synthetic staff email form.
	if staff := auth.NormalizeStaffNumber(ident); staff != "" {
		if u, err := h.Store.GetUserByStaffNumber(c.Request.Context(), staff); err == nil {
			return u, nil
		}
	}
	if auth.IsSyntheticStaffEmail(ident) {
		local := strings.SplitN(ident, "@", 2)[0]
		if staff := auth.NormalizeStaffNumber(local); staff != "" {
			if u, err := h.Store.GetUserByStaffNumber(c.Request.Context(), staff); err == nil {
				return u, nil
			}
		}
	}
	return store.User{}, store.ErrNotFound
}

// register creates a student account (always role=student, spec doc 05 §4.1).
func (h *Handlers) register(c *gin.Context) {
	var req struct {
		Email             string `json:"email"`
		Password          string `json:"password"`
		FullName          string `json:"full_name"`
		RegistrationNumber string `json:"registration_number"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Malformed request."})
		return
	}
	if len(req.Password) < 6 {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Password must be at least 6 characters."})
		return
	}
	if req.Email == "" || req.RegistrationNumber == "" {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Email and registration number are required."})
		return
	}

	hash, err := auth.HashPassword(req.Password)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Could not create account."})
		return
	}
	id, err := h.Store.CreateUser(c.Request.Context(), req.Email, req.Email, hash, req.FullName, string(auth.RoleStudent), strings.ToUpper(strings.TrimSpace(req.RegistrationNumber)))
	if err != nil {
		// Duplicate email or registration number (spec doc 05 §4.1).
		c.JSON(http.StatusBadRequest, gin.H{"detail": "An account with that email or registration number already exists."})
		return
	}

	user, _ := h.Store.GetUserByID(c.Request.Context(), id)
	ttl := time.Duration(h.Cfg.AccessTokenTTLSeconds) * time.Second
	token, _ := auth.IssueToken(h.Cfg.JWTSecret, id, auth.RoleStudent, ttl)
	c.JSON(http.StatusCreated, gin.H{"token": token, "user": user.Public()})
}

func (h *Handlers) me(c *gin.Context) {
	u, _ := auth.CurrentUser(c)
	user, err := h.Store.GetUserByID(c.Request.Context(), u.ID)
	if err != nil {
		c.JSON(http.StatusUnauthorized, gin.H{"detail": "Authentication credentials were not provided."})
		return
	}
	c.JSON(http.StatusOK, user.Public())
}

func (h *Handlers) updateMe(c *gin.Context) {
	var req struct {
		FullName string `json:"full_name"`
	}
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"detail": "Malformed request."})
		return
	}
	u, _ := auth.CurrentUser(c)
	_, err := h.Store.DB.ExecContext(c.Request.Context(),
		h.Store.UpdateFullNameQuery(), req.FullName, time.Now().UTC().Format("2006-01-02T15:04:05.000Z"), u.ID)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"detail": "Could not update profile."})
		return
	}
	h.me(c)
}
