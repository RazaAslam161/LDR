-- ───────────────────────────────────────────────────────────────────────────
-- Miles — presence.chat_last_read.
--
-- RECONSTRUCTED. Like care_nudges, this column existed only in the production
-- dashboard. The staging replay proved it: presence had 0 columns named
-- chat_last_read, while the client sends it on every presence write and
-- leave_couple() nulls it.
--
-- Two failures follow from its absence, and neither is obvious:
--
--   1. PostgREST rejects the ENTIRE upsert with PGRST204 when any named column
--      is missing — not just that field. PresenceService._upsert sends
--      chat_last_read in the same payload as is_online, app_last_active_at,
--      typing, mood and location, and its catch is bare. So on a fresh
--      database presence silently never updates at all: no online status, no
--      "where they are", no typing, no last-seen. That is exactly the symptom
--      reported for two months, and it would hit every new deployment.
--
--   2. leave_couple() sets chat_last_read = NULL. A plpgsql body is not parsed
--      until first execution, so the migration APPLIES CLEANLY and the failure
--      waits until a real user leaves a couple.
--
-- Superseded in design by chat_receipts (receipts_v2), which moved read
-- receipts out of presence — a durable fact does not belong in an ephemeral
-- row. The column stays because the shipped client still writes it, and
-- removing it would break every installed build.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.presence
  add column if not exists chat_last_read timestamptz;
