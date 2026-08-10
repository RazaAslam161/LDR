-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — Time Capsules. Run AFTER schema.sql.
-- A sealed collection of notes/photos/voice that unlocks on proximity, a date,
-- or both. Items are un-SELECTable (sealed) until capsules.unlocked_at is set.
-- Proximity is checked CLIENT-SIDE via ephemeral realtime broadcast — no
-- coordinates are ever persisted server-side (see proximity_service.dart).
-- ───────────────────────────────────────────────────────────────────────────
do $$ begin
  if not exists (select 1 from pg_type where typname='capsule_unlock_mode') then
    create type capsule_unlock_mode as enum ('proximity','date','both');
  end if;
  if not exists (select 1 from pg_type where typname='capsule_item_type') then
    create type capsule_item_type as enum ('note','photo','voice');
  end if;
end $$;

create table if not exists public.capsules (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  title       text not null,
  unlock_mode capsule_unlock_mode not null default 'date',
  unlock_date timestamptz,
  unlocked_at timestamptz,
  created_by  uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now()
);
create index if not exists capsules_couple_idx on public.capsules(couple_id, created_at desc);

create table if not exists public.capsule_items (
  id           uuid primary key default gen_random_uuid(),
  capsule_id   uuid not null references public.capsules(id) on delete cascade,
  author_id    uuid not null references public.profiles(id) on delete cascade,
  type         capsule_item_type not null,
  content_text text,
  media_url    text,
  created_at   timestamptz not null default now()
);
create index if not exists capsule_items_capsule_idx on public.capsule_items(capsule_id, created_at);

alter table public.capsules enable row level security;
alter table public.capsule_items enable row level security;

drop policy if exists "capsules_select" on public.capsules;
create policy "capsules_select" on public.capsules for select using (couple_id = public.current_user_couple_id());
drop policy if exists "capsules_insert" on public.capsules;
create policy "capsules_insert" on public.capsules for insert with check (couple_id = public.current_user_couple_id() and created_by = auth.uid());
drop policy if exists "capsules_update" on public.capsules;
create policy "capsules_update" on public.capsules for update using (couple_id = public.current_user_couple_id()) with check (couple_id = public.current_user_couple_id());
drop policy if exists "capsules_delete" on public.capsules;
create policy "capsules_delete" on public.capsules for delete using (couple_id = public.current_user_couple_id());

drop policy if exists "capsule_items_insert" on public.capsule_items;
create policy "capsule_items_insert" on public.capsule_items for insert with check (
  author_id = auth.uid()
  and capsule_id in (select id from public.capsules where couple_id = public.current_user_couple_id())
);
-- Sealed-until-unlock: items are only readable once the parent capsule is opened.
drop policy if exists "capsule_items_select_unlocked" on public.capsule_items;
create policy "capsule_items_select_unlocked" on public.capsule_items for select using (
  capsule_id in (select id from public.capsules
    where couple_id = public.current_user_couple_id() and unlocked_at is not null)
);
drop policy if exists "capsule_items_delete_own" on public.capsule_items;
create policy "capsule_items_delete_own" on public.capsule_items for delete using (
  author_id = auth.uid()
  and capsule_id in (select id from public.capsules
    where couple_id = public.current_user_couple_id() and unlocked_at is null)
);

create or replace function public.capsule_seal_summary(p_capsule_id uuid)
returns table(item_type capsule_item_type, n bigint)
language sql stable security definer set search_path = public as $$
  select i.type, count(*)::bigint
  from public.capsule_items i
  join public.capsules c on c.id = i.capsule_id
  where i.capsule_id = p_capsule_id and c.couple_id = public.current_user_couple_id()
  group by i.type;
$$;
revoke execute on function public.capsule_seal_summary(uuid) from public, anon;
grant  execute on function public.capsule_seal_summary(uuid) to authenticated;

create or replace function public.unlock_capsule(p_capsule_id uuid)
returns public.capsules
language plpgsql security definer set search_path = public as $$
declare c public.capsules;
begin
  select * into c from public.capsules
   where id = p_capsule_id and couple_id = public.current_user_couple_id();
  if not found then raise exception 'not_found'; end if;
  if c.unlocked_at is not null then return c; end if;
  if c.unlock_mode in ('date','both') then
    if c.unlock_date is null or now() < c.unlock_date then
      raise exception 'too_early';
    end if;
  end if;
  update public.capsules set unlocked_at = now() where id = p_capsule_id returning * into c;
  return c;
end; $$;
revoke execute on function public.unlock_capsule(uuid) from public, anon;
grant  execute on function public.unlock_capsule(uuid) to authenticated;

alter table public.capsules replica identity full;
do $$ begin
  if not exists (select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='capsules') then
    alter publication supabase_realtime add table public.capsules;
  end if;
end $$;

insert into storage.buckets (id, name, public) values ('capsule-media','capsule-media', false)
on conflict (id) do nothing;
drop policy if exists "capsule_media_insert" on storage.objects;
create policy "capsule_media_insert" on storage.objects for insert to authenticated
  with check (bucket_id='capsule-media' and (storage.foldername(name))[1] = public.current_user_couple_id()::text);
drop policy if exists "capsule_media_select" on storage.objects;
create policy "capsule_media_select" on storage.objects for select to authenticated
  using (bucket_id='capsule-media' and (storage.foldername(name))[1] = public.current_user_couple_id()::text);
drop policy if exists "capsule_media_delete" on storage.objects;
create policy "capsule_media_delete" on storage.objects for delete to authenticated
  using (bucket_id='capsule-media' and (storage.foldername(name))[1] = public.current_user_couple_id()::text);
