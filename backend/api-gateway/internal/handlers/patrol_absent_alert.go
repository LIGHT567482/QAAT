package handlers

// THE IN-APP ALERT IS THE NOTIFICATION CHANNEL. A monitor records a lecturer as
// NOT TAUGHT and the lecturer hears it in the same inbox they already run —
// app_notifications, polled by the phone app (AlertPoller.kt) and the web inbox
// (pages/shared/Alerts.tsx). Deliberately no email or WhatsApp: the verdict is
// read in the app it was written in, and the recipient keeps the way back
// (APPEAL_NOT_TAUGHT, migration 090) one tap away from the thing being answered
// — which no outbound copy can carry.
//
// THE TONE IS THE OFFICE ROUND'S, BECAUSE THE SHAPE IS THE SAME. "Recorded as NOT
// TAUGHT" is a record of one room at one time, not a finding that the lecturer never
// taught — and the alert never names whoever walked the corridor (patrolSenderName:
// the observation belongs to quality assurance, and the tick is the same tick no
// matter which monitor made it).
//
// BOTH ENTRY PATHS WRITE THE SAME ROW. PatrolSync (a timetabled slot synced from
// the phone) and PatrolManualEntry (an off-timetable verdict typed on the hub) call
// insertPatrolAlert with the same verdictMessage, so the two never drift: an inbox
// that softened the finding would read as a different finding, and one that
// sharpened it would read as an escalation.

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
)

// verdictMessage is the words for the in-app alert — the subject line and the
// body of the row insertPatrolAlert commits. One sentence, so there is exactly
// one version of what the lecturer is told.
func verdictMessage(l patrolLogIn) (subject, bodyTxt string) {
	when := lectureWhen(l.SessionDate, l.ScheduledTime)

	subject = fmt.Sprintf("Monitor: %s", strings.TrimSpace(l.UnitName))
	if when != "" {
		subject += " — " + when
	}

	verdict := "NOT TAUGHT"
	if l.Taught {
		verdict = "TAUGHT"
	}
	course, at, room := "", "", ""
	if strings.TrimSpace(l.CourseCode) != "" {
		course = " (" + strings.TrimSpace(l.CourseCode) + ")"
	}
	if when != "" {
		at = ", " + when
	}
	if v := strings.TrimSpace(l.Room); v != "" {
		room = ", in " + v
	}
	bodyTxt = fmt.Sprintf("You were recorded as %s for %s%s%s%s.",
		verdict, strings.TrimSpace(l.UnitName), course, at, room)

	if !l.Taught {
		bodyTxt += " If you did teach it, say so here — your account is filed " +
			"beside the monitor's and read with it. It does not overturn the tick " +
			"on its own; it makes sure there are two accounts and not one."
	}
	return subject, bodyTxt
}

// insertPatrolAlert writes one in-app alert from the QA Monitor to one recipient.
//
// The only DB write this file's caller is allowed to fail silently: the record is the
// tick, the alert is a courtesy on top of it.
func insertPatrolAlert(r *http.Request, conn *pgxpool.Conn, tenantID, subject, bodyTxt, action, actionRef, recipientUser string) {
	var nid string
	if conn.QueryRow(r.Context(), `
		INSERT INTO app_notifications (tenant_id, sender_id, sender_name, sender_role, audience, subject, body, action, action_ref)
		VALUES ($1, NULL, $2, 'QA_PATROLLER', 'DIRECT', $3, $4, NULLIF($5,''), NULLIF($6,'')) RETURNING notification_id::text`,
		tenantID, patrolSenderName, subject, bodyTxt, action, actionRef).Scan(&nid) == nil {
		_, _ = conn.Exec(r.Context(),
			`INSERT INTO notification_recipients (notification_id, tenant_id, recipient_user_id)
			 VALUES ($1, $2, $3::uuid) ON CONFLICT DO NOTHING`, nid, tenantID, recipientUser)
	}
}
