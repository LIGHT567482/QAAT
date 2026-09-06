-- Migration 107: Employee WhatsApp.
--
-- Registration for general staff AND administrators collects a WhatsApp number
-- alongside email and phone (the employee form mirrors the lecturer one: title,
-- name, staff id, whatsapp, email, department). The office-patrol alerts use it
-- exactly as they already use phone — the notification payload carries both
-- (`postNotifyWeave.direct` → `/notify/direct`), so an employee with a WhatsApp
-- but no shared desk phone still hears about their attendance record.
--
-- `whatsapp` is intentionally a SEPARATE column from `phone`: `phone` is the
-- contact the office round and the no-show report already carry, and reading one
-- field as the other would put a surveillance number on somebody's WhatsApp.
-- Administrative users already have `users.whatsapp` (migration 025); this gives
-- the employee registry the same channel without crossing the two.

ALTER TABLE employees ADD COLUMN IF NOT EXISTS whatsapp VARCHAR(40);