-- Security audit 2026-08-17. Two closures, both fail-closed and re-runnable.
--
-- 1. reconcile_storage_usage() and storage_quota_ok() were reachable over
--    /rest/v1/rpc/ by the anon role. reconcile_storage_usage aggregates the
--    whole of storage.objects and writes storage_usage; an unauthenticated
--    caller could loop it against a free-tier instance. Nothing in mobile/lib,
--    supabase/functions or web/ calls either one — the reconciler is a cron job
--    (jobid 14, */5) which runs as the job owner, and storage_quota_ok is
--    evaluated inside the storage_quota_limit INSERT policy on storage.objects.
--    authenticated therefore KEEPS execute on storage_quota_ok or every upload
--    fails; it loses execute on the reconciler, which it never called.
--
-- 2. cycle_settings_read scoped to the couple with no share_with_partner term,
--    while its siblings cycle_logs_read and cycle_events_read both gate on it.
--    The toggle hid the detail rows and left the summary row — on_period_now,
--    avg_cycle_length, avg_period_length — readable by the partner over REST
--    with the switch off. The client hide in partner_cycle_card.dart is a UI
--    hide, not an access control.
--
-- Both functions carry the default ACL entry `=X/postgres` — EXECUTE to PUBLIC.
-- anon and authenticated hold no direct grant to take away, so revoking from
-- them by name is a statement that succeeds and changes nothing; the revoke has
-- to name PUBLIC. postgres (cron job 14 runs as it) and service_role keep their
-- own explicit entries, and authenticated is re-granted on storage_quota_ok
-- below because storage_quota_limit calls it in its WITH CHECK.
--
-- Reverse with:
--   grant execute on function public.reconcile_storage_usage() to public;
--   grant execute on function public.storage_quota_ok(uuid) to public;
--   drop policy if exists cycle_settings_read on public.cycle_settings;
--   create policy cycle_settings_read on public.cycle_settings
--     for select using (user_id = (select auth.uid())
--                       or couple_id = (select public.current_user_couple_id()));

revoke execute on function public.reconcile_storage_usage() from public, anon, authenticated;
revoke execute on function public.storage_quota_ok(uuid) from public, anon;
grant execute on function public.storage_quota_ok(uuid) to authenticated;

drop policy if exists cycle_settings_read on public.cycle_settings;
create policy cycle_settings_read on public.cycle_settings
  for select using (
    user_id = (select auth.uid())
    or (couple_id = (select public.current_user_couple_id()) and share_with_partner)
  );
