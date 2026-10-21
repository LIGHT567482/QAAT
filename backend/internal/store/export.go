package store

// Q adapts a `?`-placeholder SQL string to the active driver: it returns the
// query unchanged for SQLite and rewrites placeholders to $1..$n for Postgres.
// Exported so commands (seed) and packages outside store can run portable SQL.
func (s *Store) Q(query string) string {
	return s.q(query)
}
