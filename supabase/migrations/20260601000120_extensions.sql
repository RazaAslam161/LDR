-- ───────────────────────────────────────────────────────────────────────────
-- Miles — extensions the migrations depend on.
--
-- Found while adding the diagnostics table: PRODUCTION DID NOT HAVE pg_cron.
-- Three migrations schedule cleanup jobs, and each one guards the call with
--
--   if exists (select 1 from pg_extension where extname = 'pg_cron') then
--
-- That guard was added for a good reason — cron.unschedule() raises when the
-- job is absent and aborted the whole file — but it turned "this database
-- cannot schedule anything" into a clean success. Both cleanup jobs that the
-- schema appears to define had therefore never run even once on production:
-- reach_pulses and breath_events grow forever, and nothing anywhere says so.
--
-- The guard stays, because a replay must not fail on a plan without pg_cron.
-- The fix is to stop the guard from ever being the reason: install the
-- extension here, before the first migration that schedules anything.
--
-- pg_net is listed for the same reason — the push triggers post through it, and
-- a fresh project without it would accept every INSERT and deliver no
-- notification, which is the quietest failure in the whole system.
-- ───────────────────────────────────────────────────────────────────────────

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $do$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    raise warning 'pg_cron unavailable — scheduled cleanup will not run on this project';
  end if;
end $do$;
