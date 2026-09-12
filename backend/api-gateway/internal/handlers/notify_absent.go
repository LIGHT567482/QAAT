package handlers

// Telling the students who did not attend that the session they missed is over.
//
// A session is closed by one of three people — the coordinator, the lecturer, or a lecturer
// ending an online class — and every close ends the same story: some students checked in and
// some did not. The checked-in half has a ledger row; the absent half was a silence, and a
// silence reads to a student as "nobody noticed".
//
// THIS MESSAGE IS THE NOTICE. When a session closes, every ACTIVE student in the session's
// offering who holds a user account but no attendance_logs row for that session gets a
// SESSION_ABSENT notification in their inbox. It runs only AFTER the close has already
// committed, and it is deliberately best-effort: a failed notice must never fail the close that
// already happened, so the three close handlers call it and ignore the error.
//
// A STUDENT IS TOLD, NOT REPORTED. There is no accusation and no appeal button here — the check
// is a ledger and it says what it says. The wording names the fact, not a conclusion (the same
// rule the QA patrol uses), and the remedy is pointed at the person who can actually alter the
// record, the course coordinator, because a student cannot.
//
// IDEMPOTENT PER STUDENT PER SESSION. All three close paths can land on the same session id, and
// a retried request can hit two of them. notification_log's UNIQUE (kind, subject_key,
// subject_date) is the gate; the recipient folds into the subject_key so each student claims
// their own copy and one absent student never blocks another.

import (
	"context"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/scheduler"
)

// KindSessionAbsent joins the notification_log family (migration 073). Do not rename it:
// subject_key history is keyed on it.
const KindSessionAbsent = "SESSION_ABSENT"

// absentSessionText writes the words. Separated from the DB work so the wording is checkable
// without a database — the same split employee_patrol_notify.go uses for its two messages.
func absentSessionText(unitName, at string) (subject, body string) {
	subject = "Missed session: " + unitName
	var b strings.Builder
	b.WriteString("Your ")
	b.WriteString(unitName)
	b.WriteString(" session")
	if strings.TrimSpace(at) != "" {
		b.WriteString(" at " + at)
	}
	b.WriteString(" has closed, and QAAT has no check-in from you for it.\n\n")
	b.WriteString("If you were present, ask your course coordinator to correct the attendance " +
		"record — this session shows as missed on your attendance progress.")
	return subject, b.String()
}

// notifyAbsentStudents writes the SESSION_ABSENT message to every enrolled student with an
// account who did not check in. Best-effort: an error is returned for the caller to log or
// ignore, never to fail the session close that already happened.
func notifyAbsentStudents(ctx context.Context, adminPool *pgxpool.Pool, sessionID, tenantID string) error {
	if sessionID == "" {
		return nil
	}

	var offeringID, unitID, sessionDate, unitName, at string
	err := adminPool.QueryRow(ctx, `
		SELECT COALESCE(s.offering_id::text, ''), COALESCE(s.unit_id, ''),
		       s.session_date::text, COALESCE(cu.name, ''),
		       COALESCE(to_char(s.gate_open_time, 'HH24:MI'), '')
		  FROM sessions s
		  LEFT JOIN course_units cu ON cu.unit_id = s.unit_id
		 WHERE s.session_id = $1::uuid AND s.tenant_id = $2`,
		sessionID, tenantID).Scan(&offeringID, &unitID, &sessionDate, &unitName, &at)
	if err != nil {
		return err
	}
	// A session with no offering has no enrollment to compare attendance against.
	if offeringID == "" {
		return nil
	}

	day, err := time.Parse("2006-01-02", sessionDate)
	if err != nil {
		return err
	}

	rows, err := adminPool.Query(ctx, `
		SELECT s.student_id, u.user_id::text
		  FROM students_extended s
		  JOIN users u ON lower(u.email) = lower(s.email) AND u.tenant_id = $1
		 WHERE s.tenant_id = $1 AND s.offering_id = $2::uuid AND s.enrollment_status = 'ACTIVE'
		   AND NOT EXISTS (
		       SELECT 1 FROM attendance_logs al
		        WHERE al.tenant_id = $1 AND al.session_id = $3::uuid
		          AND al.student_id = s.student_id
		   )`,
		tenantID, offeringID, sessionID)
	if err != nil {
		return err
	}
	defer rows.Close()

	subject, body := absentSessionText(unitName, at)
	for rows.Next() {
		var regNo, userID string
		if rows.Scan(&regNo, &userID) != nil {
			continue
		}
		// The recipient folds into the subject_key: notification_log's uniqueness is per
		// (kind, subject_key, subject_date), so one claim per student per session.
		already, err := scheduler.AlreadySent(ctx, adminPool, tenantID,
			KindSessionAbsent, sessionID+":"+userID, day, userID, "APP")
		if err != nil || already {
			continue
		}
		if err := writeInAppTo(ctx, adminPool, tenantID, unitID, subject, body, userID); err != nil {
			return err
		}
	}
	return rows.Err()
}

// writeInAppTo inserts one SYSTEM notification and fans it out to a single recipient. This is
// the data-plane equivalent of the jobs package's send path, writing through the BYPASSRLS
// admin connection the notification handlers already use, so no RLS tenant context is needed.
func writeInAppTo(ctx context.Context, pool *pgxpool.Pool, tenantID, unitID, subject, body, recipientUserID string) error {
	var nid string
	err := pool.QueryRow(ctx, `
		INSERT INTO app_notifications (tenant_id, sender_id, sender_name, sender_role, audience, unit_id, subject, body)
		VALUES ($1, NULL, 'QAAT', 'SYSTEM', 'DIRECT', NULLIF($2,''), $3, $4)
		RETURNING notification_id::text`,
		tenantID, unitID, subject, body).Scan(&nid)
	if err != nil {
		return err
	}
	_, err = pool.Exec(ctx, `
		INSERT INTO notification_recipients (notification_id, tenant_id, recipient_user_id)
		VALUES ($1, $2, $3::uuid) ON CONFLICT DO NOTHING`, nid, tenantID, recipientUserID)
	return err
}
