package store

// UpdateFullNameQuery returns the driver-appropriate UPDATE for a user's
// full name. Uses positional placeholders (? for SQLite, $n for Postgres).
func (s *Store) UpdateFullNameQuery() string {
	return s.q(`UPDATE users SET full_name = ?, updated_at = ? WHERE id = ?`)
}
