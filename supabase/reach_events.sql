-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — Reach (Issue 8). Run AFTER schema.sql.
-- One partner reaches → a row is inserted → the other's app shows a full-screen
-- alert (foreground via realtime; background screen-wake is the FCM follow-up
-- documented in lib/core/push/fcm_todo.dart). Location columns for Issue 2 live
-- in presence_and_mood.sql.
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists public.reach_events (
  id              uuid primary key default gen_random_uuid(),
  couple_id       uuid not null references public.couples(id) on delete cascade,
  from_user       uuid not null references public.profiles(id) on delete cascade,
  created_at      timestamptz not null default now(),
  acknowledged_at timestamptz,
  expires_at      timestamptz not null default (now() + interval '30 seconds')
);
create index if not exists reach_events_couple_idx
  on public.reach_events(couple_id, created_at);

alter table public.reach_events enable row level security;
drop policy if exists "reach_select" on public.reach_events;
create policy "reach_select" on public.reach_events
  for select using (couple_id = public.current_user_couple_id());
drop policy if exists "reach_insert" on public.reach_events;
create policy "reach_insert" on public.reach_events
  for insert with check (
    couple_id = public.current_user_couple_id() and from_user = auth.uid()
  );
drop policy if exists "reach_update" on public.reach_events;
create policy "reach_update" on public.reach_events
  for update using (couple_id = public.current_user_couple_id())
  with check (couple_id = public.current_user_couple_id());

alter table public.reach_events replica identity full;
do $$ begin
  if not exists (select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='reach_events') then
    alter publication supabase_realtime add table public.reach_events;
  end if;
end $$;
