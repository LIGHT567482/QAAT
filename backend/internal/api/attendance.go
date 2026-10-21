package api

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"qaat/backend/internal/attendance"
	"qaat/backend/internal/auth"
)

// registerAttendanceRoutes wires the attendance endpoints for a role group.
// They are ROUTED and ROLE-GUARDED but return 501 until the attendance engine
// merges in (spec doc 06). The merge fills internal/attendance and flips these
// handlers — the route table and client wiring stay untouched, so the merge
// has no conflicts.
func registerAttendanceRoutes(rg *gin.RouterGroup, role auth.Role) {
	pending := gin.H{
		"error": "attendance logic pending merge",
		"spec":  attendance.SpecRef,
	}
	abort501 := func(c *gin.Context) {
		c.JSON(http.StatusNotImplemented, pending)
	}

	// Shared read surface.
	rg.GET("/lists", abort501)
	rg.GET("/lists/:id", abort501)
	rg.GET("/roll", abort501)

	switch role {
	case auth.RoleStudent:
		// Student check-in surface (spec doc 06 §4).
		rg.POST("/check-in", abort501)
		rg.GET("/sessions/:id/roll", abort501)
	case auth.RoleLecturer:
		// Lecturer session lifecycle (spec doc 06 §3).
		rg.POST("/lists", abort501)
		rg.POST("/lists/:id/sessions", abort501)
		rg.POST("/sessions/:id/end", abort501)
		rg.POST("/sessions/:id/roll-discard", abort501)
	}
}
