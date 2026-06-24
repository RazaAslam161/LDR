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
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- Drop the previous job if it exists, then re-create.
    perform cron.unschedule('miles_breath_cleanup');
    perform cron.schedule(
      'miles_breath_cleanup',
      '0 3 * * *',
      $$delete from public.breath_events where created_at < now() - interval '1 day';$$
    );
  end if;
end $$;
