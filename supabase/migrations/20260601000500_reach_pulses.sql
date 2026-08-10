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
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- Two bugs lived here and neither could ever have run.
    --
    -- 1. The job body was quoted with a bare $$ while nested inside a do $$
    --    block, so the inner $$ terminated the outer one: "syntax error at or
    --    near delete". The outer block is tagged $do$ now, so the plain $$
    --    inside it is just text.
    -- 2. cron.unschedule() RAISES when the job does not exist, so on any
    --    database that had never run this file the statement aborted before
    --    reaching cron.schedule. It is guarded on the catalogue now.
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
