-- 0001_identity.sql — identity & accounts (spec docs/qaat-spec/03-database.md §2)
-- Dual-engine: PostgreSQL 16 (prod) / SQLite (dev-CI). All PKs are text/uuid
-- strings, never auto-increment (client-generated ids must work).
-- No BEGIN/COMMIT here — the migration runner owns transactions.

CREATE TABLE users (
  id            TEXT PRIMARY KEY,
  username      TEXT NOT NULL UNIQUE,
  email         TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  full_name     TEXT NOT NULL DEFAULT '',
  role          TEXT NOT NULL DEFAULT 'student'
                CHECK (role IN ('student','lecturer','qa_staff','administrator','kiu_admin')),
  registration_number TEXT,
  staff_number  TEXT UNIQUE,
  email_verified BOOLEAN NOT NULL DEFAULT FALSE,
  is_active     BOOLEAN NOT NULL DEFAULT TRUE,
  is_staff      BOOLEAN NOT NULL DEFAULT FALSE,
  is_superuser  BOOLEAN NOT NULL DEFAULT FALSE,
  kiu_admin_job_title TEXT,
  kiu_admin_onboarding_complete BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TEXT,
  updated_at    TEXT
);
CREATE UNIQUE INDEX users_email_lower ON users (LOWER(email));
CREATE INDEX users_registration_number_idx ON users (registration_number);

-- Claims on registration numbers (uppercased PK), reserved at register time.
CREATE TABLE student_registrations (
  registration_number TEXT PRIMARY KEY,
  user_id             TEXT REFERENCES users(id) ON DELETE CASCADE,
  email_verified_at_link TEXT,
  created_at          TEXT
);

CREATE TABLE staff_numbers (
  staff_number TEXT PRIMARY KEY,
  user_id      TEXT REFERENCES users(id) ON DELETE SET NULL,
  email        TEXT NOT NULL DEFAULT '',
  full_name    TEXT NOT NULL DEFAULT ''
);

-- Opaque auth tokens. Multiple per user allowed (multi-device), unlike the
-- legacy one-token behavior (spec doc 05 §8 enhancement).
CREATE TABLE auth_tokens (
  key          TEXT PRIMARY KEY,
  user_id      TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_at   TEXT,
  last_used_at TEXT
);
CREATE INDEX auth_tokens_user_idx ON auth_tokens (user_id);

-- sha256-hex of the raw token; raw token only ever appears in the email link.
-- verification TTL 48h, reset TTL 2h (spec doc 05 §5, §6).
CREATE TABLE email_tokens (
  id         TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL CHECK (kind IN ('verify_email','password_reset')),
  token_hash TEXT NOT NULL UNIQUE,
  expires_at TEXT NOT NULL,
  used_at    TEXT,
  created_at TEXT
);
CREATE INDEX email_tokens_user_kind_idx ON email_tokens (user_id, kind);

CREATE TABLE push_devices (
  player_id  TEXT PRIMARY KEY,
  user_id    TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  platform   TEXT NOT NULL DEFAULT 'unknown',
  tags       TEXT NOT NULL DEFAULT '{}',  -- JSON object (SQLite TEXT / PG JSONB via cast)
  created_at TEXT,
  updated_at TEXT
);
CREATE INDEX push_devices_user_idx ON push_devices (user_id);
