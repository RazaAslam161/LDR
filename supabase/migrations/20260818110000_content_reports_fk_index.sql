-- The one unindexed foreign key the advisor names:
-- content_reports.reported_user_id. Deleting a user cascades (or checks)
-- through this FK with a sequential scan of every report ever filed — cheap
-- at three users, a table scan per account deletion at thousands.
--
-- Second run: no-op.
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   drop index if exists public.content_reports_reported_user_id_idx;
-- ───────────────────────────────────────────────────────────────────────────

create index if not exists content_reports_reported_user_id_idx
  on public.content_reports (reported_user_id);
