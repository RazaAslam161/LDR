-- The shared daily chart.
--
-- Two tables, and the split is what makes "resets every day" free: the ITEMS
-- are the couple's list, and a CHECK is one row per (item, person, date). A new
-- day simply has no rows yet, so there is nothing to reset, no cron to run, and
-- no midnight job that can fail and leave yesterday's ticks standing. It also
-- keeps yesterday, which is what a streak would later be built from.
--
-- on_date is supplied by the CLIENT, deliberately. These two are in different
-- timezones — that is the premise of the app — so "today" is each person's own
-- local date. A server-side date would tick over at a moment that is midnight
-- for neither of them.
create table if not exists public.routine_items (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null references public.couples(id) on delete cascade,
  title        text not null,
  emoji        text,
  -- Minutes from midnight, so the chart reads down the day in the order it is
  -- actually lived rather than the order things were added.
  sort_minutes int  not null default 0,
  -- Water is "eight times", a prayer is once. One column covers both, and the
  -- check row counts up rather than flipping.
  target_count int  not null default 1,
  is_default   boolean not null default false,
  created_by   uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  deleted      boolean not null default false
);

create index if not exists routine_items_couple_idx
  on public.routine_items (couple_id, sort_minutes) where not deleted;

create table if not exists public.routine_checks (
  item_id  uuid not null references public.routine_items(id) on delete cascade,
  user_id  uuid not null references public.profiles(id)      on delete cascade,
  on_date  date not null,
  count    int  not null default 1,
  primary key (item_id, user_id, on_date)
);

create index if not exists routine_checks_day_idx
  on public.routine_checks (on_date, item_id);

alter table public.routine_items  enable row level security;
alter table public.routine_checks enable row level security;

drop policy if exists routine_items_member on public.routine_items;
create policy routine_items_member on public.routine_items
  for select using (couple_id = (select public.current_user_couple_id()));
drop policy if exists routine_items_insert on public.routine_items;
create policy routine_items_insert on public.routine_items
  for insert with check (couple_id = (select public.current_user_couple_id()));
-- Either partner may edit or remove an item on a SHARED chart; it is one list
-- the two of them keep, not two lists side by side.
drop policy if exists routine_items_update on public.routine_items;
create policy routine_items_update on public.routine_items
  for update using (couple_id = (select public.current_user_couple_id()))
          with check (couple_id = (select public.current_user_couple_id()));

-- Checks are visible to both — seeing whether the other one ate is the point —
-- but only ever WRITTEN by their owner. Ticking something on your partner's
-- behalf would make the chart a record of what you claim about them.
drop policy if exists routine_checks_member on public.routine_checks;
create policy routine_checks_member on public.routine_checks
  for select using (item_id in (select id from public.routine_items
                                 where couple_id = (select public.current_user_couple_id())));
drop policy if exists routine_checks_own_insert on public.routine_checks;
create policy routine_checks_own_insert on public.routine_checks
  for insert with check (user_id = auth.uid());
drop policy if exists routine_checks_own_update on public.routine_checks;
create policy routine_checks_own_update on public.routine_checks
  for update using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists routine_checks_own_delete on public.routine_checks;
create policy routine_checks_own_delete on public.routine_checks
  for delete using (user_id = auth.uid());

revoke all on public.routine_items  from anon;
revoke all on public.routine_checks from anon;
revoke truncate, references, trigger on public.routine_items  from authenticated, anon;
revoke truncate, references, trigger on public.routine_checks from authenticated, anon;
revoke delete on public.routine_items from authenticated;
revoke update on public.routine_items from authenticated;
grant select, insert on public.routine_items to authenticated;
grant update (title, emoji, sort_minutes, target_count, deleted)
  on public.routine_items to authenticated;
grant select, insert, update, delete on public.routine_checks to authenticated;

-- Seeds the couple's chart once. Idempotent: a couple that already has items
-- keeps them, so this is safe to call on every open and needs no "first run"
-- flag anywhere in the client — which would otherwise have to stay in sync
-- across two handsets that seed independently.
create or replace function public.ensure_default_routines()
returns void language plpgsql security definer set search_path = public as $fn$
declare c uuid := (select public.current_user_couple_id());
begin
  if c is null then return; end if;
  if exists (select 1 from public.routine_items where couple_id = c) then
    return;
  end if;
  insert into public.routine_items (couple_id, title, emoji, sort_minutes, target_count, is_default)
  values
    (c, 'Good morning',  '🌅', 6*60,        1, true),
    (c, 'Fajr',          '🕌', 5*60+15,     1, true),
    (c, 'Breakfast',     '🍳', 8*60,        1, true),
    (c, 'Dhuhr',         '🕌', 13*60,       1, true),
    (c, 'Lunch',         '🍚', 13*60+30,    1, true),
    (c, 'Asr',           '🕌', 16*60+30,    1, true),
    (c, 'Maghrib',       '🕌', 18*60+45,    1, true),
    (c, 'Dinner',        '🍽️', 20*60,       1, true),
    (c, 'Isha',          '🕌', 20*60+30,    1, true),
    -- Not a single tick: eight glasses across the day, counted up. Sorted last
    -- only because it belongs to the whole day rather than a moment in it.
    (c, 'Water',         '💧', 23*60+59,    8, true);
end $fn$;

revoke all on function public.ensure_default_routines() from public, anon;
grant execute on function public.ensure_default_routines() to authenticated;

do $do$ begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public'
                    and tablename='routine_checks') then
    alter publication supabase_realtime add table public.routine_checks;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public'
                    and tablename='routine_items') then
    alter publication supabase_realtime add table public.routine_items;
  end if;
end $do$;

do $do$ begin
  if has_table_privilege('authenticated','public.routine_items','DELETE') then
    raise exception 'routine_items must be soft-delete only';
  end if;
end $do$;
