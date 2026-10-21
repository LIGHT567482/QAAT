-- 0002_attendance.sql — attendance domain (spec docs/qaat-spec/03-database.md §3)
-- Schema only: engine logic is the merge slot (docs/qaat-spec/06-attendance-module.md).
-- No BEGIN/COMMIT — the migration runner owns transactions.

CREATE TABLE attendance_lists (
  id            TEXT PRIMARY KEY,          -- epoch-millis string, client-generated
  title         TEXT NOT NULL DEFAULT '',
  name          TEXT,
  room          TEXT NOT NULL DEFAULT '',
  time          TEXT NOT NULL DEFAULT '',  -- lesson time label, e.g. '08:00-10:00'
  who_taught    TEXT NOT NULL DEFAULT '',
  date          TEXT NOT NULL DEFAULT '',  -- YYYY-MM-DD
  program       TEXT NOT NULL DEFAULT '',
  courses       TEXT NOT NULL DEFAULT '[]',-- JSON array of strings
  year          TEXT,
  sem           TEXT,
  status        TEXT NOT NULL DEFAULT 'draft',
  created_by    TEXT NOT NULL DEFAULT '',
  lecturer_uid  TEXT NOT NULL DEFAULT '',
  expected_participants INTEGER,
  lecturer_sign_code    TEXT,
  lecturer_signed_at    TEXT,
  course_unit_name      TEXT,
  created_at    TEXT,
  updated_at    TEXT
);
CREATE INDEX attendance_lists_lecturer_date_idx ON attendance_lists (lecturer_uid, date);
CREATE INDEX attendance_lists_date_idx ON attendance_lists (date);
CREATE INDEX attendance_lists_status_idx ON attendance_lists (status);

CREATE TABLE attendance_sessions (
  id            TEXT PRIMARY KEY,          -- epoch-millis string
  list_id       TEXT NOT NULL,
  session_code  TEXT NOT NULL,             -- join code 'A12B', normalized uppercase
  start_time    TEXT,
  end_time      TEXT,
  status        TEXT NOT NULL DEFAULT 'active',
  latitude      DOUBLE PRECISION,
  longitude     DOUBLE PRECISION,
  radius_meters INTEGER NOT NULL DEFAULT 1500,
  remote_learning             BOOLEAN NOT NULL DEFAULT FALSE,
  location_metadata_pending   BOOLEAN NOT NULL DEFAULT FALSE,
  roll_discarded              BOOLEAN NOT NULL DEFAULT FALSE,
  session_gps_accuracy_meters DOUBLE PRECISION,
  created_by    TEXT NOT NULL DEFAULT '',
  finalized     BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TEXT,
  updated_at    TEXT
);
-- No two ACTIVE sessions may share a session_code (QAAT hardening, spec doc 03 §3.2).
CREATE UNIQUE INDEX attendance_sessions_active_code_uniq
  ON attendance_sessions (session_code) WHERE status = 'active';
CREATE INDEX attendance_sessions_list_status_idx ON attendance_sessions (list_id, status);
CREATE INDEX attendance_sessions_status_end_idx ON attendance_sessions (status, end_time);

CREATE TABLE attendance_students (
  id                 TEXT PRIMARY KEY,      -- client-generated
  list_id            TEXT NOT NULL,
  student_uid        TEXT NOT NULL,
  registration_number TEXT NOT NULL DEFAULT '',
  full_name          TEXT NOT NULL DEFAULT '',
  course             TEXT NOT NULL DEFAULT '',
  three_digit_code   TEXT,                  -- 100-999 roster code
  initials           TEXT,                  -- 2-4 uppercase letters
  created_at         TEXT,
  UNIQUE (list_id, student_uid)
);
CREATE INDEX attendance_students_uid_idx ON attendance_students (student_uid);
CREATE INDEX attendance_students_regno_idx ON attendance_students (registration_number);

CREATE TABLE attendance_sign_ins (
  id                 TEXT PRIMARY KEY,
  list_id            TEXT NOT NULL,
  student_uid        TEXT NOT NULL,
  registration_number TEXT NOT NULL DEFAULT '',
  course             TEXT NOT NULL DEFAULT '',
  created_at         TEXT,
  UNIQUE (list_id, student_uid)
);
CREATE INDEX attendance_sign_ins_uid_idx ON attendance_sign_ins (student_uid);

-- Authoritative outcomes. Record id = '{sessionId}_{studentId}' (composite PK).
-- Merge rule: verified present > unverified present > absent (spec doc 11 §2).
CREATE TABLE attendance_records (
  session_id TEXT NOT NULL,
  student_id TEXT NOT NULL,
  list_id    TEXT NOT NULL,
  course     TEXT NOT NULL DEFAULT '—',
  present    BOOLEAN NOT NULL,
  verified   BOOLEAN NOT NULL DEFAULT FALSE,
  timestamp  TEXT,
  latitude   DOUBLE PRECISION,
  longitude  DOUBLE PRECISION,
  device_id  TEXT,
  created_at TEXT,
  updated_at TEXT,
  PRIMARY KEY (session_id, student_id)
);
CREATE INDEX attendance_records_session_idx ON attendance_records (session_id);
CREATE INDEX attendance_records_list_idx ON attendance_records (list_id);
CREATE INDEX attendance_records_student_idx ON attendance_records (student_id);
CREATE INDEX attendance_records_present_idx ON attendance_records (session_id) WHERE present = TRUE;

-- Raw student submissions, adjudicated by the merge-slot engine into
-- accepted/rejected with one of the six exact rejection strings (spec doc 06 §4.4).
CREATE TABLE attendance_check_in_attempts (
  id             TEXT PRIMARY KEY,
  session_id     TEXT,
  session_code_raw TEXT,
  list_id        TEXT,
  student_id     TEXT,
  device_id      TEXT,
  course         TEXT,
  status         TEXT NOT NULL DEFAULT 'pending',
  rejection_reason TEXT,
  awaiting_session BOOLEAN NOT NULL DEFAULT FALSE,
  captured_at      TEXT,
  client_submitted_at TEXT,
  latitude       DOUBLE PRECISION,
  longitude      DOUBLE PRECISION,
  gps_accuracy_meters DOUBLE PRECISION,
  created_at     TEXT,
  updated_at     TEXT
);
CREATE INDEX attendance_attempts_sweep_idx
  ON attendance_check_in_attempts (status, awaiting_session, created_at);
CREATE INDEX attendance_attempts_session_device_idx
  ON attendance_check_in_attempts (session_id, device_id);
