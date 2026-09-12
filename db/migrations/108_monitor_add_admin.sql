-- 108: MONITOR-ADDED ADMINISTRATORS — OFF by default.
--
-- A QA monitor walks the offices round and can, at the administration's choosing, create a
-- new ADMINISTRATOR account straight from their phone ("add an administrator", built into the
-- offices round). This is an ADD-only channel: nothing anywhere on the phone can edit or remove
-- an account (removing someone is a deliberate office act, not something a corridor observer
-- should be able to do). The whole feature hangs off one switch on `tenants`; it is OFF until an
-- administrator turns it on, so a monitor cannot create accounts by default. Accounts created
-- this way start on the public staff default ("staff") with force_password_change = true — the
-- same first-login contract every provisioned account has — so they get the person in once and
-- are replaced before the account reaches any role UI.

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS monitors_can_add_admins BOOLEAN NOT NULL DEFAULT false;