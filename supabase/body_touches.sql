-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — Touch (Issue 5). Run AFTER schema.sql.
-- Ephemeral touch glows between partners on an illustrated silhouette. Rows
-- auto-expire; the client only listens for live inserts and animates them.
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists public.body_touches (
  id         uuid primary key default gen_random_uuid(),
  couple_id  uuid not null references public.couples(id) on delete cascade,
  from_user  uuid not null references public.profiles(id) on delete cascade,
  body_zone  text not null,
  touch_type text not null default 'glow',   -- 'glow' | 'kiss' | 'hug'
  intensity  real not null default 1.0,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 seconds')
);
create index if not exists body_touches_couple_idx
  on public.body_touches(couple_id, created_at);

alter table public.body_touches enable row level security;
drop policy if exists "body_touches_select" on public.body_touches;
create policy "body_touches_select" on public.body_touches
  for select using (couple_id = public.current_user_couple_id());
drop policy if exists "body_touches_insert" on public.body_touches;
create policy "body_touches_insert" on public.body_touches
  for insert with check (
    couple_id = public.current_user_couple_id() and from_user = auth.uid()
  );

alter table public.body_touches replica identity full;
do $$ begin
  if not exists (select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='body_touches') then
    alter publication supabase_realtime add table public.body_touches;
  end if;
end $$;
