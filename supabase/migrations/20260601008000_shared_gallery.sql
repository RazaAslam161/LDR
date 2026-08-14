-- The vault becomes a shared gallery: plaintext, two objects per item, realtime.
--
-- WHY THE ENCRYPTION GOES (product decision, 2026-08-15, stated by the owner):
-- every slow thing about the vault traces to one property — the bytes cannot be
-- painted until the device has fetched them whole and run XChaCha20 over them.
-- That defeats every mechanism a fast gallery is built on: no HTTP range
-- requests, no CDN, no progressive decode, no browser-grade image cache, and a
-- decrypt on the UI isolate per tile. The spinners are not a bug in the vault
-- screen; they are the design working as specified.
--
-- Plaintext objects behind signed URLs let this reuse the CHAT pipeline
-- verbatim, which is already fast: a small thumb object per item, a shared
-- decode width so one frame serves grid and pager, and flutter_cache_manager
-- holding bytes on disk between launches.
--
-- The honest cost, recorded here because the UI must stop claiming otherwise:
-- Supabase can read these photos. "Nothing here is readable by anyone but the
-- two of you — not even us" (closer_screen.dart) is FALSE for anything stored
-- this way and has to change in the same release.
--
-- vault_items is NOT dropped. It holds the couple's existing encrypted history
-- and nine memory rows; deleting it would destroy data that is still readable
-- on their devices. The gallery is a new table beside it.

create table if not exists public.gallery_items (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null references public.couples(id)  on delete cascade,
  uploaded_by  uuid          references public.profiles(id) on delete set null,
  -- Both are object names inside couple_intimate, couple_id first so the
  -- existing storage policies apply unchanged.
  storage_path text not null,
  thumb_path   text,
  mime_type    text not null default 'image/jpeg',
  -- Reserving the tile's aspect BEFORE the bytes arrive is what stops the grid
  -- reflowing as pictures land — the "previews jump around" complaint. Plain
  -- integers are safe here precisely because the media is no longer secret.
  width        int,
  height       int,
  byte_size    bigint,
  caption      text,
  created_at   timestamptz not null default now(),
  deleted      boolean not null default false,
  deleted_at   timestamptz,
  deleted_by   uuid          references public.profiles(id) on delete set null
);

-- The grid query: this couple, newest first, not deleted.
create index if not exists gallery_items_couple_idx
  on public.gallery_items (couple_id, created_at desc) where not deleted;

alter table public.gallery_items enable row level security;

drop policy if exists gallery_select_member on public.gallery_items;
create policy gallery_select_member on public.gallery_items
  for select using (couple_id = (select public.current_user_couple_id()));

drop policy if exists gallery_insert_member on public.gallery_items;
create policy gallery_insert_member on public.gallery_items
  for insert with check (uploaded_by = auth.uid()
    and couple_id = (select public.current_user_couple_id()));

-- Either partner may caption or remove anything in a SHARED gallery — that is
-- what shared means, and it matches how a phone's own gallery behaves. The
-- dual-consent machinery stays where it belongs, on memory_threads, which is
-- the one object in this app that two people jointly author.
drop policy if exists gallery_update_member on public.gallery_items;
create policy gallery_update_member on public.gallery_items
  for update using (couple_id = (select public.current_user_couple_id()))
          with check (couple_id = (select public.current_user_couple_id()));

revoke all on public.gallery_items from anon;
-- DELETE and table-wide UPDATE arrive uninvited: Supabase's default privileges
-- grant ALL on every new table to authenticated, which is the same mechanism
-- that handed TRUNCATE to key_escrow and memory_photos (see 007010 — it
-- disarmed the default for truncate/references/trigger only). A hard delete
-- here would drop the row before the reaper could read its paths, stranding the
-- bytes in the bucket permanently, exactly as 007500 documents.
revoke delete, update on public.gallery_items from authenticated;
grant select, insert on public.gallery_items to authenticated;
-- Soft delete only: the objects must be reaped through the Storage API, and a
-- hard row delete would lose the paths before that can happen.
grant update (caption, deleted, deleted_at, deleted_by) on public.gallery_items
  to authenticated;

-- Removing an item queues its objects for the reaper that 007500 built, so
-- "deleted" means the bytes actually go rather than the row merely hiding.
create or replace function public._gallery_reap()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.deleted and not old.deleted then
    insert into public.storage_reap (bucket_id, name)
    values ('couple_intimate', new.storage_path)
    on conflict do nothing;
    if new.thumb_path is not null then
      insert into public.storage_reap (bucket_id, name)
      values ('couple_intimate', new.thumb_path)
      on conflict do nothing;
    end if;
  end if;
  return new;
end $fn$;
drop trigger if exists gallery_items_reap on public.gallery_items;
create trigger gallery_items_reap after update of deleted on public.gallery_items
  for each row execute function public._gallery_reap();

-- "Instantly shown to both users" is this line. Without it the partner's upload
-- appears on the next manual refresh, which is the difference between a shared
-- gallery and two galleries.
do $do$ begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public'
                    and tablename='gallery_items') then
    alter publication supabase_realtime add table public.gallery_items;
  end if;
end $do$;
alter table public.gallery_items replica identity default;

do $do$
declare n int;
begin
  select count(*) into n from information_schema.columns
   where table_schema='public' and table_name='gallery_items';
  if n = 0 then raise exception 'gallery_items was not created'; end if;
  if has_table_privilege('authenticated','public.gallery_items','DELETE') then
    raise exception 'gallery_items must be soft-delete only, or the reaper loses the paths';
  end if;
end $do$;
