-- ───────────────────────────────────────────────────────────────────────────
-- Miles — Breath Sync events table
-- Run this in the Supabase SQL editor AFTER schema.sql.
--
-- Holds one row per "begin cycle" press so the partner's client can sync
-- via realtime. Rows expire automatically after a day (TTL).
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.breath_events (
  id            uuid primary key default gen_random_uuid(),
  couple_id     uuid not null references public.couples(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  started_at    bigint not null,         -- ms since epoch
  created_at    timestamptz not null default now()
);
create index if not exists breath_events_couple_idx
  on public.breath_events(couple_id, created_at desc);

-- RLS: members of the couple can read + write.
alter table public.breath_events enable row level security;

drop policy if exists "breath_events_select_member" on public.breath_events;
create policy "breath_events_select_member" on public.breath_events
  for select using (couple_id = public.current_user_couple_id());

drop policy if exists "breath_events_insert_member" on public.breath_events;
create policy "breath_events_insert_member" on public.breath_events
  for insert with check (couple_id = public.current_user_couple_id());

-- Auto-clean rows older than 1 day (run nightly).
-- We use pg_cron if available, falling back to manual cleanup.
-- Two bugs lived here and neither could ever have run.
--
--   1. The job body was quoted with a bare doubled-dollar while nested inside
--      a doubled-dollar do block, so the inner tag terminated the outer one.
--      Distinct tags fix it: the block is tagged do, the body job.
--   2. cron.unschedule() RAISES when the job does not exist, so on a database
--      that had never run this file the statement aborted before
--      cron.schedule was reached. It is gated on cron.job now.
--
-- This explanation sits OUTSIDE the block on purpose: dollar quoting ignores
-- SQL comments, so naming a tag inside the block would close it early — which
-- is exactly how the first attempt at this fix failed.
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'miles_breath_cleanup') then
      perform cron.unschedule('miles_breath_cleanup');
    end if;
    perform cron.schedule(
      'miles_breath_cleanup',
      '0 3 * * *',
      $job$delete from public.breath_events where created_at < now() - interval '1 day';$job$
    );
  end if;
end $do$;
