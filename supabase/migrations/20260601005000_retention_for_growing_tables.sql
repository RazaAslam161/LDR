-- ───────────────────────────────────────────────────────────────────────────
-- Miles — five tables that grow forever, and the one that grows fastest is
-- the one added yesterday.
--
-- MEASURED, not assumed. diag_events reached 21,448 rows and 9MB from ONE
-- couple in ONE day of instrumentation. At five thousand couples that is
-- roughly 107 MILLION rows a day, and no retention window makes it survivable.
-- The instrumentation built to find the fleet's bugs would have been the thing
-- that took the fleet down — the exact shape of mistake this audit exists for:
-- correct for two people, fatal for everyone.
--
-- The client no longer uploads unless someone turns diagnostics on (they are
-- opt-in as of build 2), but a bound belongs here as well, because the client
-- is the half an operator does not control.
--
-- The other four had no retention at all and accumulate per couple forever:
--
--   call_invites   one offer SDP per call. An SDP carries the device's private
--                  AND public IP addresses, so keeping them indefinitely is a
--                  location history nobody asked for and nobody reads.
--   call_signals   ICE/offer/answer traffic. Same content, same argument.
--   body_touches   one row per touch gesture; 331 from two people.
--   reach_events   one row per reach.
--   care_nudges    one row per nudge.
--
-- None of these is read after the moment it happens. They exist to fire a
-- notification and to render briefly.
--
-- Verified live: body_touches 331 -> 0, call_invites 50 -> 33,
-- reach_events 81 -> 39, care_nudges 57 -> 30.
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.prune_ephemera()
returns void language plpgsql security definer set search_path = public as $fn$
begin
  delete from public.call_invites where created_at < now() - interval '2 days';
  delete from public.call_signals where created_at < now() - interval '1 day';
  delete from public.body_touches  where created_at < now() - interval '7 days';
  delete from public.reach_events  where created_at < now() - interval '30 days';
  delete from public.care_nudges   where created_at < now() - interval '30 days';
end $fn$;

revoke execute on function public.prune_ephemera() from public, anon, authenticated;

-- Two days rather than seven. A trace is read while the bug is being chased,
-- not a week later, and this is the one table that scales with every couple at
-- once.
create or replace function public.prune_diag_events()
returns void language sql security definer set search_path = public as $fn$
  delete from public.diag_events where received_at < now() - interval '2 days';
$fn$;
revoke execute on function public.prune_diag_events() from public, anon, authenticated;

do $do$
begin
  if exists (select 1 from pg_extension where extname='pg_cron') then
    if exists (select 1 from cron.job where jobname='prune-ephemera') then
      perform cron.unschedule('prune-ephemera');
    end if;
    perform cron.schedule('prune-ephemera', '41 2 * * *',
      'select public.prune_ephemera()');
  end if;
end $do$;
