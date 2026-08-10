-- MESSAGE PRIVACY NOTE
-- Messages are couple-scoped by RLS.
-- When users leave and re-pair, old messages are automatically invisible
-- because couple_id no longer matches current_user_couple_id().
-- No deletion needed — RLS acts as the privacy wall.
-- Old messages are preserved in case users re-pair with the same person
-- (a brand-new couple_id is generated on every pairing, so they are NOT
-- auto-restored; that would require storing and reusing the old couple_id).
SELECT 'Message privacy enforced by RLS' AS note;
