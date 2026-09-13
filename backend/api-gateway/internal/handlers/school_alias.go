package handlers

// One school, two names — and both have to match.
//
// A college has a formal title ("School of Mathematics and Computing") and the short form everyone
// actually uses ("SOMAC"). Migration 072 stores both. This file is the single place that knows they
// are the same thing.
//
// WHY IT MATTERS MORE THAN A LABEL. `users.school` and `courses.school` are free TEXT, and every
// org-scoped query is a string comparison between them: a dean sees their college because
// `courses.school` equals the value on their account. Real institutions have been entering the
// abbreviation as the name (this deployment's only school is literally called "SOMAC"), so historic
// rows hold the short form. The instant an admin fills in the full title, a matcher that knew only
// `schools.name` would compare the long form against rows holding the short one and every scoped
// dashboard would empty out — which reads as "no data" rather than "mismatch", and is therefore the
// hardest kind of failure to diagnose.
//
// So a school reference resolves to the SET of strings that mean it, and matching accepts any.

import (
	"context"
	"net/http"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/qaat/api-gateway/internal/middleware"
)

// schoolAliases returns every string that identifies the same school as `ref` — its full name and
// its abbreviation — matched case- and whitespace-insensitively against either.
//
// `ref` itself is always included, even when no school record matches it: a department or account
// may name a college that was never added to the org tree, and that value must still scope to
// exactly what it says rather than silently widening to nothing.
func schoolAliases(ctx context.Context, pool *pgxpool.Pool, tenantID, ref string) []string {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return nil
	}
	out := []string{ref}
	seen := map[string]bool{strings.ToLower(ref): true}

	// Over a TENANT-SCOPED connection: `schools` is RLS-protected, and a pool connection with no
	// app.current_tenant sees none of it. Read that way the alias lookup silently found nothing,
	// so a dean whose account says "SOMAC" stopped matching courses filed under the full title —
	// the exact orphaning this function exists to prevent, failing quietly.
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return out
	}
	defer conn.Release()
	if middleware.SetTenantConn(ctx, conn, tenantID) != nil {
		return out
	}
	rows, err := conn.Query(ctx, `
		SELECT name, COALESCE(abbreviation,'')
		FROM schools
		WHERE tenant_id = $1
		  AND (btrim(lower(name)) = btrim(lower($2))
		    OR btrim(lower(COALESCE(abbreviation,''))) = btrim(lower($2)))`,
		tenantID, ref)
	if err != nil {
		// The scope still works on the literal value; it just does not gain the alias.
		return out
	}
	defer rows.Close()
	for rows.Next() {
		var name, abbr string
		if rows.Scan(&name, &abbr) != nil {
			continue
		}
		for _, v := range []string{name, abbr} {
			v = strings.TrimSpace(v)
			if v == "" || seen[strings.ToLower(v)] {
				continue
			}
			seen[strings.ToLower(v)] = true
			out = append(out, v)
		}
	}
	return out
}

// normaliseAliases lower-cases and trims a set for comparison against
// `btrim(lower(column)) = ANY(...)`, which is how the alias list is used in SQL.
func normaliseAliases(in []string) []string {
	out := make([]string, 0, len(in))
	for _, v := range in {
		if v = strings.ToLower(strings.TrimSpace(v)); v != "" {
			out = append(out, v)
		}
	}
	return out
}

// monitorScopeSchools returns the normalised set of school names a QA monitor covers — the rows of
// qa_monitor_schools that an admin assigned, on top of the single legacy users.school column —
// each expanded through the alias table so a match still lands on rows filed under the other name.
//
// The second return is false when the sender is not a QA monitor or has no school assigned;
// callers then use the institution-wide reach that was the QA officer's remit, which is also what
// the DQA director always gets. A monitor with nothing assigned is effectively the whole
// institution; a monitor with schools assigned is bounded to exactly them.
func monitorScopeSchools(pool *pgxpool.Pool, r *http.Request, tenantID, senderID, senderRole string) ([]string, bool) {
	if senderRole != middleware.RoleQAMonitor {
		return nil, false
	}
	var school string
	_ = pool.QueryRow(r.Context(),
		`SELECT COALESCE(school,'') FROM users WHERE user_id = $1::uuid AND tenant_id = $2`,
		senderID, tenantID).Scan(&school)
	var names []string
	if strings.TrimSpace(school) != "" {
		names = append(names, school)
	}
	rows, err := pool.Query(r.Context(), `
		SELECT s.name
		  FROM qa_monitor_schools q
		  JOIN schools s ON s.school_id = q.school_id
		 WHERE q.user_id = $1::uuid AND q.tenant_id = $2
		 ORDER BY s.name`, senderID, tenantID)
	if err == nil {
		for rows.Next() {
			var n string
			if rows.Scan(&n) == nil && strings.TrimSpace(n) != "" {
				names = append(names, n)
			}
		}
		rows.Close()
	}
	if len(names) == 0 {
		return nil, false
	}
	seen := map[string]bool{}
	var aliases []string
	for _, n := range names {
		for _, a := range schoolAliases(r.Context(), pool, tenantID, n) {
			a = strings.TrimSpace(strings.ToLower(a))
			if a != "" && !seen[a] {
				seen[a] = true
				aliases = append(aliases, a)
			}
		}
	}
	return aliases, true
}

// monitorSchools returns every school name an ADMIN has assigned a QA monitor through
// qa_monitor_schools (migration 110) — on top of the single legacy users.school column.
//
// The QA officer / patroller / school-handler roles were merged into QA_MONITOR, and with
// the merge the school list stopped being a value on the account: an admin manages the
// monitor's colleges on the Users page, and that list — NOT the account — is the scope of
// every QA dashboard and report the monitor reads. Returns names (not ids) because every
// scoped query in this codebase matches on courses.school BY NAME.
func monitorSchools(ctx context.Context, pool *pgxpool.Pool, tenantID, userID string) []string {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return nil
	}
	defer conn.Release()
	if middleware.SetTenantConn(ctx, conn, tenantID) != nil {
		return nil
	}
	rows, err := conn.Query(ctx, `
		SELECT s.name
		  FROM qa_monitor_schools q
		  JOIN schools s ON s.school_id = q.school_id
		 WHERE q.user_id = $1::uuid
		 ORDER BY s.name`, userID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		if rows.Scan(&n) == nil && strings.TrimSpace(n) != "" {
			out = append(out, n)
		}
	}
	return out
}

// userSchools returns every school name a user has been given through user_schools
// (migration 075), on top of the single legacy users.school column.
//
// A QA school handler covers several colleges. Before the join table existed the
// account could hold exactly one, so the handler's other schools were not
// "forbidden" — they were absent, which reads as an empty institution rather than
// as a missing permission. That is the failure this closes.
//
// Returns names (not ids) because every scoped query in this codebase matches on
// courses.school BY NAME; ids would need a different join in a dozen places.
func userSchools(ctx context.Context, pool *pgxpool.Pool, tenantID, userID string) []string {
	// Same reason as schoolAliases above: user_schools and schools are both RLS-protected, so
	// without the tenant GUC this returned nothing and a QA school handler saw only their legacy
	// users.school column — every other college assigned to them simply absent, which is the
	// problem migration 075 added this table to solve.
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return nil
	}
	defer conn.Release()
	if middleware.SetTenantConn(ctx, conn, tenantID) != nil {
		return nil
	}
	rows, err := conn.Query(ctx, `
		SELECT s.name
		  FROM user_schools us
		  JOIN schools s ON s.school_id = us.school_id
		 WHERE us.user_id = $1::uuid
		 ORDER BY s.name`, userID)
	if err != nil {
		return nil
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var n string
		if rows.Scan(&n) == nil && strings.TrimSpace(n) != "" {
			out = append(out, n)
		}
	}
	return out
}
