-- 110: The QA monitor role label.
--
-- The three QA field roles (OFFICER, PATROLLER, SCHOOL HANDLER) merge into ONE — QA_MONITOR,
-- a job a single person already does. This migration only adds the enum label, by itself and in
-- its own transaction: Postgres refuses to *use* a freshly added enum value in the same
-- transaction as ADD VALUE (SQLSTATE 55P04), and the value must be committed and visible before
-- 111 rewrites the accounts that hold the old labels. The ledger makes this the safe ordering.

ALTER TYPE user_role_enum ADD VALUE IF NOT EXISTS 'QA_MONITOR';