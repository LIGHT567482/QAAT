package handlers

// Employee registry — general (non-teaching) staff AND administrators whose attendance is
// monitored by the QA office round and the check-in tablet. Deliberately SEPARATE from lecturers
// and students: its own registration flow + its own bulk import/export template.
// Columns: staff_id, title, full_name, department, job_title, email, phone, whatsapp, office.
//
// WHO IS AN EMPLOYEE HERE. Anyone who is monitored as office staff, including the administrators
// of the support offices — Finance, Admissions, Bursary, Library, ICT, Estates — and academic
// departments. Registration mirrors the lecturer form (title, name, staff id, whatsapp, email,
// department) because the monitor's office round is what records them.
//
// `department` is OPTIONAL, and deliberately: the Vice Chancellor, a Deputy Vice Chancellor and
// other senior offices sit ABOVE the department ladder and belong to none of them. It means two
// things.
//
//  1. A department is a CLAIM about where the round will knock; it is canonicalised against the
//     tenant's real departments when one is given, so a typo can't file somebody under nothing.
//  2. When no department is given the row simply has none. The coverage report already handles
//     that — it shows COALESCE(NULLIF(department,''), 'Unassigned') — so a VC is chased under
//     their office, grouped as Unassigned, rather than being invisible or mis-filed.
//
// `office` is where the QA office round starts looking (migration 106). It is optional — unlike
// department, which the no-show report groups by — and the monitor records what they actually
// found, which may differ.

import (
	"context"
	"fmt"
	"net/http"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// requireDepartment refuses anything that is not one of the tenant's departments — SUPPORT or
// ACADEMIC — and returns the department's CANONICAL name.
//
// The name is matched case- and whitespace-insensitively because it is stored as free text on the
// employee row. Both kinds of departments are accepted: since administrators are monitored too,
// an office in an academic faculty has exactly the same standing as one under ICT — filing a dean's
// secretary under their department is the point, not a mistake. Rejecting a name that does not exist
// at all is what keeps a typo from filing somebody under nothing, which reads as a department with
// no staff rather than as a mistake.
//
// WHY THE CANONICAL NAME IS RETURNED, AND MUST BE STORED. `employees.department` is a NAME, and the
// no-show report GROUPs BY it. Storing whatever casing the caller happened to type — "finance" from
// a CSV, "Finance" from the form — would split one department into two rows that each show half the
// staff, with nothing on screen to explain why. Matching loosely and storing exactly is what keeps
// the group whole.
func requireDepartment(ctx context.Context, pool *pgxpool.Pool, tenantID, name string) (string, error) {
	var canonical string
	err := pool.QueryRow(ctx, `
		SELECT name FROM departments
		WHERE tenant_id = $1 AND btrim(lower(name)) = btrim(lower($2))
		LIMIT 1`, tenantID, name).Scan(&canonical)
	if err != nil {
		return "", fmt.Errorf("no department named %q exists — add it under Schools & Departments first", name)
	}
	return canonical, nil
}

// GET /api/v1/admin/tenants/{tenant_id}/employees
func ListEmployees(adminPool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := tenantOf(r)
		rows, err := adminPool.Query(r.Context(), `
			SELECT employee_pk::text, staff_id, COALESCE(title,''), full_name,
			       COALESCE(department,''), COALESCE(job_title,''), COALESCE(email,''),
			       COALESCE(phone,''), COALESCE(whatsapp,''), COALESCE(office,''), is_active
			FROM employees WHERE tenant_id = $1 ORDER BY full_name`, tenantID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		defer rows.Close()
		type employee struct {
			EmployeePK string `json:"employee_pk"`
			StaffID    string `json:"staff_id"`
			Title      string `json:"title"`
			FullName   string `json:"full_name"`
			Department string `json:"department"`
			JobTitle   string `json:"job_title"`
			Email      string `json:"email"`
			Phone      string `json:"phone"`
			Whatsapp   string `json:"whatsapp"`
			Office     string `json:"office"`
			IsActive   bool   `json:"is_active"`
		}
		list := []employee{}
		for rows.Next() {
			var e employee
			if err := rows.Scan(&e.EmployeePK, &e.StaffID, &e.Title, &e.FullName,
				&e.Department, &e.JobTitle, &e.Email, &e.Phone, &e.Whatsapp, &e.Office, &e.IsActive); err != nil {
				continue
			}
			list = append(list, e)
		}
		writeJSON(w, http.StatusOK, list)
	}
}

type employeeReq struct {
	StaffID    string `json:"staff_id"`
	Title      string `json:"title"`
	FullName   string `json:"full_name"`
	Department string `json:"department"`
	JobTitle   string `json:"job_title"`
	Email      string `json:"email"`
	Phone      string `json:"phone"`
	Whatsapp   string `json:"whatsapp"`
	// Where the QA office round starts looking. Optional — see the file header.
	Office string `json:"office"`
}

// POST /api/v1/admin/tenants/{tenant_id}/employees
func CreateEmployee(adminPool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := tenantOf(r)
		var req employeeReq
		if err := decodeJSON(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "malformed JSON"))
			return
		}
		req.StaffID = strings.TrimSpace(req.StaffID)
		req.FullName = strings.TrimSpace(req.FullName)
		req.Department = strings.TrimSpace(req.Department)
		if req.StaffID == "" || req.FullName == "" {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "staff_id and full_name are required"))
			return
		}
		// A department is optional — the VC sits above every department — but WHEN one is given it
		// must be real, and it is canonicalised here: the registry stores what Schools & Departments
		// calls it, so the coverage report's per-department grouping stays whole.
		if req.Department != "" {
			canonical, derr := requireDepartment(r.Context(), adminPool, tenantID, req.Department)
			if derr != nil {
				writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", derr.Error()))
				return
			}
			req.Department = canonical
		}
		var pk string
		err := adminPool.QueryRow(r.Context(), `
			INSERT INTO employees (tenant_id, staff_id, title, full_name, department, job_title, email, phone, whatsapp, office)
			VALUES ($1,$2,NULLIF($3,''),$4,NULLIF($5,''),NULLIF($6,''),NULLIF($7,''),NULLIF($8,''),NULLIF($9,''),NULLIF($10,''))
			ON CONFLICT (tenant_id, staff_id) DO UPDATE SET
			    title      = COALESCE(NULLIF(EXCLUDED.title,''), employees.title),
			    full_name  = EXCLUDED.full_name,
			    department = COALESCE(NULLIF(EXCLUDED.department,''), employees.department),
			    job_title  = COALESCE(NULLIF(EXCLUDED.job_title,''), employees.job_title),
			    email      = COALESCE(NULLIF(EXCLUDED.email,''), employees.email),
			    phone      = COALESCE(NULLIF(EXCLUDED.phone,''), employees.phone),
			    whatsapp   = COALESCE(NULLIF(EXCLUDED.whatsapp,''), employees.whatsapp),
			    office     = COALESCE(NULLIF(EXCLUDED.office,''), employees.office)
			RETURNING employee_pk::text`,
			tenantID, req.StaffID, req.Title, req.FullName, req.Department, req.JobTitle, req.Email, req.Phone,
			req.Whatsapp, strings.TrimSpace(req.Office)).Scan(&pk)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"employee_pk": pk, "status": "SAVED"})
	}
}

// PATCH /api/v1/admin/employees/{id}
func UpdateEmployee(adminPool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := chi.URLParam(r, "id")
		var req employeeReq
		if err := decodeJSON(r, &req); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "malformed JSON"))
			return
		}
		// Same rule as creation, or an edit would be the way around it: a department is optional,
		// but when one is given it must be real. The route carries no tenant, so it comes from the
		// row being edited.
		req.Department = strings.TrimSpace(req.Department)
		var tenantID string
		if err := adminPool.QueryRow(r.Context(),
			`SELECT tenant_id::text FROM employees WHERE employee_pk = $1`, id).Scan(&tenantID); err != nil {
			writeJSON(w, http.StatusNotFound, errBody("NOT_FOUND", "employee not found"))
			return
		}
		if req.Department != "" {
			canonical, derr := requireDepartment(r.Context(), adminPool, tenantID, req.Department)
			if derr != nil {
				writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", derr.Error()))
				return
			}
			req.Department = canonical
		}
		ct, err := adminPool.Exec(r.Context(), `
			UPDATE employees SET
			    staff_id   = COALESCE(NULLIF($2,''), staff_id),
			    title      = NULLIF($3,''),
			    full_name  = COALESCE(NULLIF($4,''), full_name),
			    department = NULLIF($5,''),
			    job_title  = NULLIF($6,''),
			    email      = NULLIF($7,''),
			    phone      = NULLIF($8,''),
			    whatsapp   = NULLIF($9,''),
			    office     = NULLIF($10,'')
			WHERE employee_pk = $1`,
			id, strings.TrimSpace(req.StaffID), req.Title, strings.TrimSpace(req.FullName),
			req.Department, req.JobTitle, req.Email, req.Phone, req.Whatsapp, strings.TrimSpace(req.Office))
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		if ct.RowsAffected() == 0 {
			writeJSON(w, http.StatusNotFound, errBody("NOT_FOUND", "employee not found"))
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "UPDATED"})
	}
}

// DELETE /api/v1/admin/employees/{id}
func DeleteEmployee(adminPool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := chi.URLParam(r, "id")
		ct, err := adminPool.Exec(r.Context(), `DELETE FROM employees WHERE employee_pk = $1`, id)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		if ct.RowsAffected() == 0 {
			writeJSON(w, http.StatusNotFound, errBody("NOT_FOUND", "employee not found"))
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "DELETED"})
	}
}

// POST /api/v1/admin/tenants/{tenant_id}/employees/import  (multipart field "roster")
func ImportEmployees(adminPool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := tenantOf(r)
		if err := r.ParseMultipartForm(32 << 20); err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "expected multipart/form-data"))
			return
		}
		file, _, err := r.FormFile("roster")
		if err != nil {
			writeJSON(w, http.StatusBadRequest, errBody("INVALID_REQUEST", "field 'roster' not found"))
			return
		}
		defer file.Close()

		rows, idx, err := readTabular(file)
		if err != nil {
			writeJSON(w, http.StatusUnprocessableEntity, errBody("CSV_PARSE_ERROR", err.Error()))
			return
		}
		if _, ok := idx["staff_id"]; !ok {
			writeJSON(w, http.StatusUnprocessableEntity, errBody("CSV_PARSE_ERROR", "missing required column: staff_id"))
			return
		}
		if _, ok := idx["full_name"]; !ok {
			writeJSON(w, http.StatusUnprocessableEntity, errBody("CSV_PARSE_ERROR", "missing required column: full_name"))
			return
		}
		// `department` stays a real column in the template — most staff file under one — but it is
		// OPTIONAL here exactly as in the form: an import line for the Vice Chancellor has no
		// department to name, and refusing the batch over it would block the very senior offices
		// the round exists to cover. A blank cell files the row under no department.
		// The tenant's departments, resolved once: a per-row query would be a round trip
		// per line, and the set cannot change mid-import. Maps the loose form to the CANONICAL
		// name so a file full of "finance" does not create a second group beside "Finance" — the
		// no-show report groups by this string. Both SUPPORT and ACADEMIC departments are valid:
		// an administrator in an academic office is monitored exactly like one under ICT.
		depts := map[string]string{}
		if drows, derr := adminPool.Query(r.Context(),
			`SELECT btrim(lower(name)), name FROM departments WHERE tenant_id = $1`, tenantID); derr == nil {
			for drows.Next() {
				var lower, canonical string
				if drows.Scan(&lower, &canonical) == nil {
					depts[lower] = canonical
				}
			}
			drows.Close()
		}

		res := &importResult{Errors: []string{}}
		for ln := 1; ln < len(rows); ln++ {
			row := rows[ln]
			staffID := cell(row, idx, "staff_id")
			fullName := cell(row, idx, "full_name")
			if staffID == "" || fullName == "" {
				res.Skipped++
				res.Errors = append(res.Errors, fmt.Sprintf("line %d: staff_id and full_name required", ln))
				continue
			}
			dept := strings.TrimSpace(cell(row, idx, "department"))
			if dept != "" {
				canonical, ok := depts[strings.ToLower(dept)]
				if !ok {
					res.Skipped++
					res.Errors = append(res.Errors, fmt.Sprintf(
						"line %d: %q is not one of this institution's departments", ln, dept))
					continue
				}
				dept = canonical
			}
			var inserted bool
			err := adminPool.QueryRow(r.Context(), `
				INSERT INTO employees (tenant_id, staff_id, title, full_name, department, job_title, email, phone, whatsapp, office)
				VALUES ($1,$2,NULLIF($3,''),$4,NULLIF($5,''),NULLIF($6,''),NULLIF($7,''),NULLIF($8,''),NULLIF($9,''),NULLIF($10,''))
				ON CONFLICT (tenant_id, staff_id) DO UPDATE SET
				    title      = COALESCE(NULLIF(EXCLUDED.title,''), employees.title),
				    full_name  = EXCLUDED.full_name,
				    department = COALESCE(NULLIF(EXCLUDED.department,''), employees.department),
				    job_title  = COALESCE(NULLIF(EXCLUDED.job_title,''), employees.job_title),
				    email      = COALESCE(NULLIF(EXCLUDED.email,''), employees.email),
				    phone      = COALESCE(NULLIF(EXCLUDED.phone,''), employees.phone),
				    whatsapp   = COALESCE(NULLIF(EXCLUDED.whatsapp,''), employees.whatsapp),
				    -- COALESCE, not a plain assignment: a file exported before the office column
				    -- existed, or one an administrator trimmed down, must not silently clear the
				    -- offices the round is prefilling from.
				    office     = COALESCE(NULLIF(EXCLUDED.office,''), employees.office)
				RETURNING (xmax = 0)`,
				tenantID, staffID, cell(row, idx, "title"), fullName,
				dept, cell(row, idx, "job_title"),
				cell(row, idx, "email"), cell(row, idx, "phone"),
				cell(row, idx, "whatsapp"),
				cell(row, idx, "office")).Scan(&inserted)
			if err != nil {
				res.Skipped++
				res.Errors = append(res.Errors, fmt.Sprintf("line %d: %s", ln, err.Error()))
				continue
			}
			if inserted {
				res.Inserted++
			} else {
				res.Updated++
			}
		}
		writeJSON(w, http.StatusOK, res)
	}
}

// GET /api/v1/admin/tenants/{tenant_id}/employees/export.xlsx
func ExportEmployeesXLSX(adminPool *pgxpool.Pool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		tenantID := tenantOf(r)
		rows, err := adminPool.Query(r.Context(), `
			SELECT staff_id, COALESCE(title,''), full_name, COALESCE(department,''),
			       COALESCE(job_title,''), COALESCE(email,''), COALESCE(phone,''),
			       COALESCE(whatsapp,''), COALESCE(office,'')
			FROM employees WHERE tenant_id = $1 ORDER BY full_name`, tenantID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		defer rows.Close()
		// office rides along because this export IS the import template: an administrator
		// downloads it, edits it and uploads it again, so a column the export drops is a column
		// the next import has no value for. whatsapp gets the same treatment — it was added to
		// the registry and to the import in the same breath, and the two must stay in step.
		out := [][]string{{"staff_id", "title", "full_name", "department", "job_title", "email", "phone", "whatsapp", "office"}}
		for rows.Next() {
			var sid, title, name, dept, job, email, phone, whatsapp, office string
			rows.Scan(&sid, &title, &name, &dept, &job, &email, &phone, &whatsapp, &office) //nolint:errcheck
			out = append(out, []string{sid, title, name, dept, job, email, phone, whatsapp, office})
		}
		xlsx, err := buildXLSX(out)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errBody("INTERNAL_ERROR", err.Error()))
			return
		}
		w.Header().Set("Content-Type", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
		w.Header().Set("Content-Disposition", `attachment; filename="employees.xlsx"`)
		_, _ = w.Write(xlsx)
	}
}
