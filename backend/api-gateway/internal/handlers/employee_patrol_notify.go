package handlers

// Telling somebody what the office round recorded.
//
// AN EMPTY OFFICE IS AN ACCUSATION, and the lecture round learned what that costs. A patrol alert
// used to arrive under the patroller's own name, so a lecturer opened their inbox and read "From
// Jane Doe" above "you were recorded as NOT TAUGHT" — which turns an institutional observation
// into one colleague accusing another, and is the fast way to make monitors unwilling to record
// what they saw. patrolSenderName exists to stop that: the observation belongs to quality
// assurance, and the tick is the same tick whoever walked the corridor. Nothing is lost to
// accountability — employee_patrol_logs stores patroller_id, patroller_name and
// patroller_staff_id on every row, and the QA reports read them. The name is simply not what the
// subject of the record is shown.
//
// THE OFFICE ROUND NEEDS THAT RULE AND ONE MORE. A monitor who knocked once and found nobody has
// established exactly one thing: that at that minute, that door had nobody behind it. It has NOT
// established that the person was absent from work, was not on approved leave, was not at a
// meeting two buildings away, or was not back in the room ninety seconds later. A message that
// says or implies otherwise is a finding the evidence does not carry — sent over WhatsApp, to
// somebody with no dashboard on which to answer it.
//
// WHY THERE IS NO APPEAL BUTTON. A lecturer told they did not teach gets APPEAL_NOT_TAUGHT
// (migration 090) pointed at that exact lecture, because lecturers have accounts and an in-app
// inbox. Employees have neither — migration 047 is explicit that they are badge numbers managed by
// an administrator, not logins. So the message routes the answer to somewhere a person actually
// is: their head of department. That is a worse remedy than the lecturer's and it is worth saying
// so plainly rather than pretending the two are equivalent.
//
// TWO MESSAGES, WITH DIFFERENT FREQUENCIES. Every visit the round syncs produces an email and a
// WhatsApp to the person it was about:
//
//   - AT_OFFICE / ELSEWHERE_ON_DUTY — a CONFIRMATION that their attendance was taken, keyed to the
//     SPECIFIC visit. "They receive an email each time their attendance is taken" is the literal
//     requirement: a morning round and an afternoon round are two attendances and two messages.
//     The visit id is what stops a RETRIED sync re-sending the same row.
//   - ABSENT — the warning below, deduped to ONE per person per day. An accusation is not a
//     confirmation; telling the same person three times in one morning that their office was
//     empty is not three pieces of information, it is one piece of information repeated until it
//     becomes harassment. A correction that flips ELSEWHERE→ABSENT must still reach them, and
//     AlreadySent on the day is the single source of truth for whether it already did.
//
// The present-verdict confirmation is what stops the channel from reading as purely punitive:
// the only time an employee ever hears from QA used to be when an office was empty. Now the same
// round that records them present tells them so. The absence message is still worded as a record
// rather than a charge — the "read together" sentence is load-bearing rather than decorative.

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/clock"
	"github.com/qaat/api-gateway/internal/scheduler"
)

// KindEmployeeOfficeAbsent joins the EMPLOYEE_* family in notification_log (migration 073).
const KindEmployeeOfficeAbsent = "EMPLOYEE_OFFICE_ABSENT"

// KindEmployeeAttendanceTaken is the present-verdict CONFIRMATION — keyed on the visit, not the
// day, because the requirement is one message per time attendance is taken (see the file header).
const KindEmployeeAttendanceTaken = "EMPLOYEE_ATTENDANCE_TAKEN"

// attendanceTakenMessage builds the confirmation a person gets when the round recorded them as
// present. Deliberately the inverse of the absence warning: it names the door and the moment too,
// it never names the monitor, and where the absence message must not claim somebody was away, this
// one may plainly say what was recorded — there is no accusation here to soften.
func attendanceTakenMessage(office, visitDate, visitTime, status string) (subject, body string) {
	when := lectureWhen(visitDate, visitTime)
	where := strings.TrimSpace(office)

	subject = "QA office round — attendance recorded"
	if when != "" {
		subject += " — " + when
	}

	// What was written on the row. Only the two present verdicts reach this message, but the
	// fallback keeps it readable if a future verdict reuses the builder.
	recorded := "at your desk"
	if status == "ELSEWHERE_ON_DUTY" {
		recorded = "on duty elsewhere"
	}

	var b strings.Builder
	b.WriteString("A QA office round called at ")
	if where != "" {
		b.WriteString(where)
	} else {
		b.WriteString("your office")
	}
	if when != "" {
		b.WriteString(" on " + when)
	}
	b.WriteString(" and recorded you as " + recorded + ".\n\n")
	b.WriteString("This is the quality-assurance record of that moment. It is filed beside the " +
		"attendance record from the terminal — a round never moves what the machine recorded, it " +
		"adds a second account of the same day, and the two are read together.")

	return subject, b.String()
}

// officeAbsenceMessage builds the words. Separated from the sending so the rules above can be
// pinned by tests — most of them are satisfied by an ABSENCE from the text, which is exactly what
// a later edit restores without noticing.
func officeAbsenceMessage(office, visitDate, visitTime string) (subject, body string) {
	when := lectureWhen(visitDate, visitTime)
	where := strings.TrimSpace(office)

	subject = "QA office round"
	if when != "" {
		subject += " — " + when
	}

	// "called at X and found it empty" — what happened, in the words of what happened. Not
	// "you were absent", not "you were not at your desk", both of which state a conclusion the
	// visit does not support.
	var b strings.Builder
	b.WriteString("A QA office round called at ")
	if where != "" {
		b.WriteString(where)
	} else {
		b.WriteString("your office")
	}
	if when != "" {
		b.WriteString(" on " + when)
	}
	b.WriteString(" and found it empty.\n\n")
	b.WriteString("This is a record of one door at one moment. It is not a finding that you were " +
		"absent from work, and it does not replace the attendance record from the terminal — the " +
		"two are filed side by side and read together.\n\n")
	b.WriteString("If you were on duty elsewhere at that time — a meeting, a campus errand, leave " +
		"already approved — tell your head of department so that account is on file beside this one.")

	return subject, b.String()
}

// tenantBranding fetches the tenant's display name + email domain in one row. The domain
// matters: /notify/direct holds no branding today, the notification-service falls back to a
// qaat.local sender, and most real relays refuse "noreply@qaat.local" out of hand. Best-effort
// — a transient DB blip just leaves the fallback in place.
func tenantBranding(r *http.Request, pool *pgxpool.Pool, tenantID string) (name, domain string) {
	_ = pool.QueryRow(r.Context(), `SELECT COALESCE(name,''), COALESCE(domain,'') FROM tenants WHERE tenant_id=$1`, tenantID).Scan(&name, &domain)
	return name, domain
}

// notifyOfficeAbsence claims the day, then sends. Best-effort throughout: a failure here never
// fails the sync, because the visit is the record that matters and the notice is a courtesy on
// top of it.
func notifyOfficeAbsence(r *http.Request, pool *pgxpool.Pool, tenantID, tenantName string, t officeAbsenceTarget) {
	// Nobody to send to. Skipped silently rather than counted as sent, the same rule
	// jobs/employees.go applies by filtering these out of its sweep: a message with no addressee
	// that is recorded as delivered is worse than one that was never attempted.
	if strings.TrimSpace(t.Email) == "" && strings.TrimSpace(t.Phone) == "" {
		return
	}

	day, err := clock.ParseDate(t.VisitDate)
	if err != nil {
		day = clock.Now()
	}
	// ONE MESSAGE PER PERSON PER DAY, keyed on the badge number — so a round that syncs three
	// times, or a monitor who corrects a verdict, does not send it again. Two empty offices in one
	// day is one story about that day; two identical WhatsApps is harassment.
	already, err := scheduler.AlreadySent(r.Context(), pool, tenantID,
		KindEmployeeOfficeAbsent, t.StaffID, day, "", "EMAIL,WHATSAPP")
	if err != nil || already {
		return
	}

	subject, body := officeAbsenceMessage(t.Office, t.VisitDate, t.VisitTime)
	tName, tDomain := tenantBranding(r, pool, tenantID)
	payload, _ := json.Marshal(map[string]interface{}{
		"tenant":  tenantName,
		"subject": subject,
		"message": body,
		"branding": map[string]string{"name": tName, "domain": tDomain},
		"recipients": []map[string]string{{
			"name": t.Name, "email": t.Email, "phone": t.Phone, "department": t.Department,
		}},
	})
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost,
		notifyURL()+"/notify/direct", bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 10 * time.Second}
	if resp, err := client.Do(req); err == nil {
		_ = resp.Body.Close()
	}
}

// notifyAttendanceTaken confirms a present verdict. Best-effort throughout, same as the absence
// notice: the visit is the record that matters, the message is a courtesy on top of it.
//
// The claim is keyed on the VISIT, not the person-day: the whole point is an email each time
// attendance is taken, so two rounds in one day are two emails. What the visit id still buys is
// retry safety — a sync that is tried twice must not tell the person twice about the same minute.
func notifyAttendanceTaken(r *http.Request, pool *pgxpool.Pool, tenantID, tenantName string, t officeAbsenceTarget, status string) {
	if strings.TrimSpace(t.Email) == "" && strings.TrimSpace(t.Phone) == "" {
		return
	}

	day, err := clock.ParseDate(t.VisitDate)
	if err != nil {
		day = clock.Now()
	}
	key := strings.TrimSpace(t.VisitID)
	if key == "" {
		key = t.StaffID
	}
	already, err := scheduler.AlreadySent(r.Context(), pool, tenantID,
		KindEmployeeAttendanceTaken, key, day, "", "EMAIL,WHATSAPP")
	if err != nil || already {
		return
	}

	subject, body := attendanceTakenMessage(t.Office, t.VisitDate, t.VisitTime, status)
	tName, tDomain := tenantBranding(r, pool, tenantID)
	payload, _ := json.Marshal(map[string]interface{}{
		"tenant":  tenantName,
		"subject": subject,
		"message": body,
		"branding": map[string]string{"name": tName, "domain": tDomain},
		"recipients": []map[string]string{{
			"name": t.Name, "email": t.Email, "phone": t.Phone, "department": t.Department,
		}},
	})
	req, err := http.NewRequestWithContext(r.Context(), http.MethodPost,
		notifyURL()+"/notify/direct", bytes.NewReader(payload))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 10 * time.Second}
	if resp, err := client.Do(req); err == nil {
		_ = resp.Body.Close()
	}
}
