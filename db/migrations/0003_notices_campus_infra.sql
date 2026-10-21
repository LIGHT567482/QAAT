-- 0003_notices_campus_infra.sql — notices, campus domain, documents escape
-- hatch, and the transactional job outbox
-- (spec docs/qaat-spec/03-database.md §4-§7). No BEGIN/COMMIT.

CREATE TABLE notices (
  id            TEXT PRIMARY KEY,          -- e.g. 'missed_{sessionId}_{studentId}' or UUID
  title         TEXT NOT NULL DEFAULT '',
  body          TEXT NOT NULL DEFAULT '',
  kind          TEXT NOT NULL DEFAULT 'generic',
  audience      TEXT NOT NULL DEFAULT 'all',
  target_list_id    TEXT,
  target_student_id TEXT,
  target_lecturer_uid TEXT,
  session_code  TEXT,
  session_id    TEXT,
  scheduled_for TEXT,
  send_push     BOOLEAN NOT NULL DEFAULT FALSE,
  push_sent_at  TEXT,               -- idempotency stamp
  expires_at    TEXT,
  author        TEXT NOT NULL DEFAULT 'QAAT',
  created_at    TEXT,
  updated_at    TEXT
);
CREATE INDEX notices_due_push_idx
  ON notices (scheduled_for) WHERE send_push = TRUE AND push_sent_at IS NULL;
CREATE INDEX notices_kind_created_idx ON notices (kind, created_at);

CREATE TABLE campus_presence (
  id            TEXT PRIMARY KEY,
  admin_uid     TEXT NOT NULL,
  event_type    TEXT NOT NULL,             -- check_in / check_out / override
  latitude      DOUBLE PRECISION,
  longitude     DOUBLE PRECISION,
  captured_at   TEXT,
  local_date_key TEXT NOT NULL DEFAULT '', -- YYYY-MM-DD device-local grouping key
  metadata      TEXT NOT NULL DEFAULT '{}',-- JSON (accuracy, device, notes)
  created_at    TEXT
);
CREATE INDEX campus_presence_uid_date_idx ON campus_presence (admin_uid, local_date_key);
CREATE INDEX campus_presence_date_idx ON campus_presence (local_date_key);

CREATE TABLE campus_geofence (               -- singleton config row (id='campus')
  id            TEXT PRIMARY KEY DEFAULT 'campus',
  latitude      DOUBLE PRECISION,
  longitude     DOUBLE PRECISION,
  radius_meters INTEGER NOT NULL DEFAULT 200,
  label         TEXT NOT NULL DEFAULT '',
  updated_at    TEXT,
  updated_by_uid TEXT,
  updated_by_name TEXT
);

-- Generic documents escape hatch + legacy-import target (spec doc 03 §6).
CREATE TABLE documents (
  collection TEXT NOT NULL,
  doc_id     TEXT NOT NULL,
  data       TEXT NOT NULL DEFAULT '{}',   -- JSON (JSONB in PG via cast in queries)
  created_at TEXT,
  updated_at TEXT,
  PRIMARY KEY (collection, doc_id)
);
CREATE INDEX documents_collection_updated_idx ON documents (collection, updated_at);

-- Transactional outbox: enqueued in the same transaction as the domain write.
-- Drained in-process by the Go backend at the spec's cadences (30s/60s/120s).
CREATE TABLE job_outbox (
  id         TEXT PRIMARY KEY,
  topic      TEXT NOT NULL,
  payload    TEXT NOT NULL DEFAULT '{}',
  status     TEXT NOT NULL DEFAULT 'pending',
  attempts   INTEGER NOT NULL DEFAULT 0,
  run_at     TEXT,
  created_at TEXT,
  updated_at TEXT
);
CREATE INDEX job_outbox_pending_idx ON job_outbox (status, run_at);
