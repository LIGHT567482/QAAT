package api

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"qaat/backend/internal/auth"
)

// Dashboards return role-scoped summaries. Attendance-derived numbers are
// pending until the merge lands (they surface as null with a note).

func (h *Handlers) studentDashboard(c *gin.Context) {
	u, _ := auth.CurrentUser(c)
	c.JSON(http.StatusOK, gin.H{
		"user":      u.ID,
		"role":      u.Role,
		"attendance": gin.H{"status": "pending_merge", "roll": nil},
	})
}

func (h *Handlers) lecturerDashboard(c *gin.Context) {
	u, _ := auth.CurrentUser(c)
	c.JSON(http.StatusOK, gin.H{
		"user":      u.ID,
		"role":      u.Role,
		"lists":     nil,
		"attendance": gin.H{"status": "pending_merge"},
	})
}

func (h *Handlers) adminDashboard(c *gin.Context) {
	u, _ := auth.CurrentUser(c)
	c.JSON(http.StatusOK, gin.H{
		"user":      u.ID,
		"role":      u.Role,
		"overview":  nil,
		"attendance": gin.H{"status": "pending_merge"},
	})
}
