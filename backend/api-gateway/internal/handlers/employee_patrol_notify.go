package handlers

// Telling somebody their office was found empty.
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
// ONLY ABSENT IS REPORTED. AT_OFFICE and ELSEWHERE_ON_DUTY notify nobody. Email and WhatsApp are
// interruptive channels with no inbox to leave things in; a message on every visit trains the
// recipient to ignore the channel, and then the one that needed reading arrives in a stream they
// have stopped opening. The cost of that choice is real and should not be glossed: the only time
// an employee ever hears from QA is when an office was empty, which reads as purely punitive.
// That is mitigated by the wording below, not by adding noise — which is why the "read together"
// sentence is load-bearing rather than decorative.

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
	payload, _ := json.Marshal(map[string]interface{}{
		"tenant":  tenantName,
		"subject": subject,
		"message": body,
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
