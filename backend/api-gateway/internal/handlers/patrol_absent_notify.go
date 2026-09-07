package handlers

// TOLD BY THE APP IS NOT THE SAME AS HEARD, and a NOT TAUGHT verdict deserves to be
// both. The round already writes the lecturer an in-app alert (migration 090,
// APPEAL_NOT_TAUGHT) the moment a monitor ticks taught=false — but an in-app alert
// is read only by somebody who opens the app, and an accusation that exists in an
// inbox nobody has looked at is, from the lecturer's chair, no accusation at all.
// This file adds the OUTBOUND copy — email first, WhatsApp when a provider is ever
// configured — so the person the record is about actually hears it off an app.
//
// THE TONE IS THE OFFICE ROUND'S, BECAUSE THE SHAPE IS THE SAME. "Recorded as NOT
// TAUGHT" is a record of one room at one time, not a finding that the lecturer never
// taught — and the letter never names whoever walked the corridor (patrolSenderName:
// the observation belongs to quality assurance, and the tick is the same tick no
// matter which monitor made it).
//
// ONE PER SLOT, NOT PER DAY. Two sittings of one unit on the same day are two
// observations and deserve two letters; the same slot synced twice (an offline phone
// retrying, a monitor correcting a verdict) is one observation and must not be two.
// notification_log keys the claim on the slot — lecturer|unit|date|time — while the
// employee round dedups a message per person per day (an empty office twice is one
// story about the day), an absent lecture twice is two lectures.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/clock"
	"github.com/qaat/api-gateway/internal/scheduler"
)

// KindLecturerPatrolAbsent is the notification_log namespace (migration 073) for the
// outbound copy of a NOT TAUGHT verdict. It only ever claims a verdict that flips the
// lecturer to absent, so a slot first ticked TAUGHT and later corrected to NOT TAUGHT
// sends exactly one letter, and a slot re-synced as absent sends none after the first.
const KindLecturerPatrolAbsent = "LECTURER_PATROL_ABSENT"

// verdictMessage is the shared words for both channels — the in-app alert (this file's
// sibling, written from PatrolSync and PatrolManualEntry) and the email. One sentence,
// so the two never drift: an email that softens the finding reads as a different finding,
// and an in-app note that sharpens it reads as an escalation.
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

// patrolAbsentEmail is the email a lecturer gets for a NOT TAUGHT verdict: the same
// record as the in-app sentence, with the way back said for someone who is not looking
// at an inbox that just gave them the alert. "In the KIU QAAT app where this alert found
// you" points at the appeal (APPEAL_NOT_TAUGHT) without pretending an email carries a
// button.
func patrolAbsentEmail(l patrolLogIn) (subject, body string) {
	inSubject, inBody := verdictMessage(l)
	subject = "QA monitor: " + strings.TrimPrefix(inSubject, "Monitor: ")

	// "say so here" is true only in the app; an email reader has no tap-through, so say
	// where "here" is. Everything before the last sentence is the shared record.
	idx := strings.LastIndex(inBody, " If you did teach it")
	record := inBody
	if idx >= 0 {
		record = inBody[:idx]
	}
	body = record + " If you did teach it, reply in the KIU QAAT app where this alert " +
		"found you — your account is filed beside the monitor's and read with it. " +
		"It does not overturn the tick on its own; it makes sure there are two accounts " +
		"and not one."
	return subject, body
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

// notifyPatrolAbsentEmail is the OUTBOUND copy of a NOT TAUGHT verdict — the email (and
// WhatsApp) guarantee this file exists for. Claims the slot on notification_log FIRST so
// a retried sync cannot send twice, then POSTs to the notification-service /notify/direct.
//
// Best-effort and fire-and-forget: a slow relay must not stall a round sync, so the send
// runs on the caller's context for its caller-visible lifetime but never blocks the tick.
func notifyPatrolAbsentEmail(r *http.Request, pool *pgxpool.Pool, tenantID, tenantName string, l patrolLogIn, lecturerUser, lecturerName, lecturerEmail, lecturerPhone string) {
	if strings.TrimSpace(lecturerEmail) == "" && strings.TrimSpace(lecturerPhone) == "" {
		return
	}

	// The slot owns the claim. A compensation HELPING a slot the monitor originally
	// found empty keeps the same slot identity, so an absent verdict that later turns
	// into a made-good compensation does not un-send the record of what was found.
	slotKey := strings.Join(nonBlank(l.LecturerID, l.UnitID, l.SessionDate, l.ScheduledTime), "|")
	if slotKey == "" {
		return
	}
	day, err := clock.ParseDate(l.SessionDate)
	if err != nil {
		day = clock.Now()
	}

	// Claim-then-send on a context detached from the request: the verdict was already
	// committed to the ledger by the caller, and nothing left to do may fail the response.
	ctx, cancel := context.WithTimeout(context.WithoutCancel(r.Context()), 15*time.Second)
	defer cancel()

	already, err := scheduler.AlreadySent(ctx, pool, tenantID, KindLecturerPatrolAbsent, slotKey, day, lecturerUser, "EMAIL,WHATSAPP")
	if err != nil || already {
		return
	}

	subject, body := patrolAbsentEmail(l)
	tName, tDomain := tenantBranding(r, pool, tenantID)
	payload, err := json.Marshal(map[string]interface{}{
		"tenant":   tenantName,
		"subject":  subject,
		"message":  body,
		"branding": map[string]string{"name": tName, "domain": tDomain},
		"recipients": []map[string]string{{
			"name": lecturerName, "email": lecturerEmail, "phone": lecturerPhone,
		}},
	})
	if err != nil {
		return
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, notifyURL()+"/notify/direct", bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 10 * time.Second}
	if resp, err := client.Do(req); err == nil {
		_ = resp.Body.Close()
	}
}
