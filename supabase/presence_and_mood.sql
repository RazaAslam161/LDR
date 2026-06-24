-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — Presence/typing (Issue 1F) + Mood (Issue 6) + Location (Issue 2)
-- + check-in. Run AFTER schema.sql. One presence row per user, couple-scoped.
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists public.presence (
  user_id        uuid primary key references public.profiles(id) on delete cascade,
  couple_id      uuid references public.couples(id) on delete cascade,
  is_online      boolean not null default false,
  last_seen      timestamptz not null default now(),
  is_typing      boolean not null default false,
  typing_in_chat boolean not null default false,
  current_mood   text,
  mood_color     text,
  mood_updated_at timestamptz,
  -- Issue 2 (location + check-in):
  latitude       double precision,
  longitude      double precision,
  location_label text,
  location_sharing_mode text not null default 'off',   -- 'off'|'city'|'precise'
  location_accuracy double precision,                  -- Issue 2B: live map
  location_updated_at timestamptz,                     -- "updated Xs ago"
  current_activity text,
  current_screen text,                                 -- #3: which feature partner is in
  body_photo_path text,                                -- #1: Touch body photo (private bucket)
  checkin_photo_url text,
  checkin_photo_at  timestamptz,
  updated_at     timestamptz not null default now()
);
alter table public.presence enable row level security;

drop policy if exists "presence_select_couple" on public.presence;
create policy "presence_select_couple" on public.presence
  for select using (couple_id = public.current_user_couple_id());
drop policy if exists "presence_insert_self" on public.presence;
create policy "presence_insert_self" on public.presence
  for insert with check (user_id = auth.uid());
drop policy if exists "presence_update_self" on public.presence;
create policy "presence_update_self" on public.presence
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

alter table public.presence replica identity full;
do $$ begin
  if not exists (select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='presence') then
    alter publication supabase_realtime add table public.presence;
  end if;
end $$;

-- Issue 6: per-message mood tint columns.
alter table public.messages add column if not exists sender_mood       text;
alter table public.messages add column if not exists sender_mood_color text;
