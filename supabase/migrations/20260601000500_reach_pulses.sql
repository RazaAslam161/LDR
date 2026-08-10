-- ───────────────────────────────────────────────────────────────────────────
-- Miles — Reach pulses table
-- Run this in the Supabase SQL editor AFTER schema.sql.
--
-- Each row is one "heartbeat" sent via the Reach feature. The partner's
-- device subscribes via realtime and triggers a haptic pulse.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.reach_pulses (
  id            uuid primary key default gen_random_uuid(),
  couple_id     uuid not null references public.couples(id) on delete cascade,
  user_id       uuid not null references auth.users(id) on delete cascade,
  sent_at       bigint not null,         -- ms since epoch
  created_at    timestamptz not null default now()
);
create index if not exists reach_pulses_couple_idx
  on public.reach_pulses(couple_id, created_at desc);

alter table public.reach_pulses enable row level security;

drop policy if exists "reach_pulses_select_member" on public.reach_pulses;
create policy "reach_pulses_select_member" on public.reach_pulses
  for select using (couple_id = public.current_user_couple_id());

drop policy if exists "reach_pulses_insert_member" on public.reach_pulses;
create policy "reach_pulses_insert_member" on public.reach_pulses
  for insert with check (couple_id = public.current_user_couple_id());

-- Auto-clean rows older than 1 hour (these are ephemeral).
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
    if exists (select 1 from cron.job where jobname = 'miles_reach_cleanup') then
      perform cron.unschedule('miles_reach_cleanup');
    end if;
    perform cron.schedule(
      'miles_reach_cleanup',
      '*/30 * * * *',
      $job$delete from public.reach_pulses where created_at < now() - interval '1 hour';$job$
    );
  end if;
end $do$;
