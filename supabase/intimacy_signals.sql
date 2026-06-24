-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — "In the Mood" intimacy signals. Run AFTER schema.sql.
-- Tender, mutual, consent-forward; NEVER explicit. Core privacy property: you
-- can only see your partner's signal if YOU also have an active signal in the
-- window (double-blind), enforced in RLS via SECURITY DEFINER helpers so the
-- policy never self-references the table (avoids 42P17 recursion).
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists public.intimacy_prefs (
  user_id           uuid primary key references public.profiles(id) on delete cascade,
  receiving_enabled boolean not null default false,
  signaling_enabled boolean not null default false,
  updated_at        timestamptz not null default now()
);

create table if not exists public.intimacy_signals (
  id                uuid primary key default gen_random_uuid(),
  couple_id         uuid not null references public.couples(id) on delete cascade,
  user_id           uuid not null references public.profiles(id) on delete cascade,
  state             text not null,
  created_at        timestamptz not null default now(),
  window_expires_at timestamptz not null
);
create index if not exists intimacy_signals_couple_idx
  on public.intimacy_signals(couple_id, window_expires_at);

alter table public.intimacy_prefs   enable row level security;
alter table public.intimacy_signals enable row level security;

drop policy if exists "intimacy_prefs_select" on public.intimacy_prefs;
create policy "intimacy_prefs_select" on public.intimacy_prefs
  for select using (user_id = auth.uid());
drop policy if exists "intimacy_prefs_upsert" on public.intimacy_prefs;
create policy "intimacy_prefs_upsert" on public.intimacy_prefs
  for insert with check (user_id = auth.uid());
drop policy if exists "intimacy_prefs_update" on public.intimacy_prefs;
create policy "intimacy_prefs_update" on public.intimacy_prefs
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.has_active_intimacy_signal()
returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.intimacy_signals s
    where s.user_id = auth.uid() and s.window_expires_at > now());
$$;
revoke execute on function public.has_active_intimacy_signal() from public, anon;
grant  execute on function public.has_active_intimacy_signal() to authenticated;

create or replace function public.my_intimacy_signaling_enabled()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select signaling_enabled from public.intimacy_prefs
    where user_id = auth.uid()), false);
$$;
revoke execute on function public.my_intimacy_signaling_enabled() from public, anon;
grant  execute on function public.my_intimacy_signaling_enabled() to authenticated;

drop policy if exists "intimacy_signals_select" on public.intimacy_signals;
create policy "intimacy_signals_select" on public.intimacy_signals
  for select using (
    couple_id = public.current_user_couple_id()
    and (user_id = auth.uid() or public.has_active_intimacy_signal())
  );
drop policy if exists "intimacy_signals_insert" on public.intimacy_signals;
create policy "intimacy_signals_insert" on public.intimacy_signals
  for insert with check (
    couple_id = public.current_user_couple_id()
    and user_id = auth.uid()
    and public.my_intimacy_signaling_enabled()
  );
drop policy if exists "intimacy_signals_delete" on public.intimacy_signals;
create policy "intimacy_signals_delete" on public.intimacy_signals
  for delete using (user_id = auth.uid());

alter table public.intimacy_signals replica identity full;
do $$ begin
  if not exists (select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='intimacy_signals') then
    alter publication supabase_realtime add table public.intimacy_signals;
  end if;
end $$;
