-- ───────────────────────────────────────────────────────────────────────────
-- Memory Threads: the photo leaves the row.
--
-- Measured before this ran: 9 rows, all carrying a photo, avg 352,062 bytes,
-- max 1,579,965. PostgREST renders bytea as \x+hex at two chars/byte and the
-- client selected every column for the whole timeline on every realtime tick
-- (relreplident='f'). Twenty memories was ~14 MB of JSON to paint a list of
-- titles that never showed a photo.
--
-- photo_cipher/photo_nonce are KEPT. Only the couple's devices hold the key,
-- so no server-side backfill is possible. They are re-encrypted into
-- memory_photos by heal-on-read, from a device that can decrypt them, and the
-- columns are nulled per row as that happens.
--
-- Applied by name through apply_migration as `memory_threads_redesign`. This
-- file is the mirror; the ledger and these filenames share no scheme, so
-- nobody should ever run `db push` against this project.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.memory_photos (
  id             uuid primary key,
  memory_id      uuid not null references public.memory_threads(id) on delete cascade,
  couple_id      uuid not null references public.couples(id)        on delete cascade,
  added_by       uuid     references public.profiles(id)            on delete set null,
  position       int  not null,
  cover_path     text not null,
  tile_path      text not null,
  full_path      text not null,
  mime_type      text not null default 'image/jpeg',
  caption_cipher bytea, caption_nonce bytea,
  created_at     timestamptz not null default now(),
  -- DEFERRABLE so a reorder can swap two positions in one statement.
  constraint memory_photos_position_uniq unique (memory_id, position)
    deferrable initially deferred,
  constraint memory_photos_caption_pair_chk
    check ((caption_cipher is null) = (caption_nonce is null))
);
-- NO `aspect` column. The timeline cover is a fixed 16:10 and reserves its own
-- height from a layout constant; the gallery grid is fixed squares. The column
-- would have bought a real (small) plaintext leak for a reflow that cannot
-- happen. A blurhash was rejected outright for the same reason, harder: it is
-- a low-resolution copy of an intimate photo, readable by anyone with DB access.

create index if not exists memory_photos_memory_idx on public.memory_photos (memory_id, position);
create index if not exists memory_photos_couple_idx on public.memory_photos (couple_id);

-- couple_id is denormalised because the storage path is built from it. Nothing
-- in the INSERT policy could constrain it against the parent, so a mismatched
-- pair would produce rows whose objects sit under a prefix the parent's couple
-- cannot read — an unrecoverable, invisible orphan. Derive it, never take it.
create or replace function public._memory_photo_derive()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  select couple_id into new.couple_id from public.memory_threads where id = new.memory_id;
  if new.couple_id is null then raise exception 'no such memory'; end if;
  return new;
end $fn$;
drop trigger if exists memory_photos_derive on public.memory_photos;
create trigger memory_photos_derive before insert on public.memory_photos
  for each row execute function public._memory_photo_derive();

alter table public.memory_photos enable row level security;
drop policy if exists memory_photos_select_member on public.memory_photos;
create policy memory_photos_select_member on public.memory_photos
  for select using (couple_id = (select public.current_user_couple_id()));
drop policy if exists memory_photos_insert_member on public.memory_photos;
create policy memory_photos_insert_member on public.memory_photos
  for insert with check (added_by = auth.uid()
    and memory_id in (select id from public.memory_threads
                       where couple_id = (select public.current_user_couple_id())));
drop policy if exists memory_photos_update_member on public.memory_photos;
create policy memory_photos_update_member on public.memory_photos
  for update using (couple_id = (select public.current_user_couple_id()))
          with check (couple_id = (select public.current_user_couple_id()));
-- Removing the MEMORY is dual-consent. Removing one photo you contributed is
-- an edit to your own contribution.
drop policy if exists memory_photos_delete_own on public.memory_photos;
create policy memory_photos_delete_own on public.memory_photos
  for delete using (couple_id = (select public.current_user_couple_id())
                    and added_by = auth.uid());

revoke all on public.memory_photos from anon;
revoke update on public.memory_photos from authenticated;
grant select, insert, delete on public.memory_photos to authenticated;
grant update (position, caption_cipher, caption_nonce) on public.memory_photos to authenticated;

-- ── Parent columns ─────────────────────────────────────────────────────────
alter table public.memory_threads
  add column if not exists cover_photo_id      uuid references public.memory_photos(id) on delete set null,
  add column if not exists cover_path          text,
  add column if not exists cover_tile_path     text,
  add column if not exists photo_count         int not null default 0,
  add column if not exists last_photo_at       timestamptz,
  add column if not exists place_cipher        bytea,
  add column if not exists place_nonce         bytea,
  add column if not exists visit_id            uuid references public.visits(id) on delete set null,
  add column if not exists partner_note_cipher bytea,
  add column if not exists partner_note_nonce  bytea;

alter table public.memory_threads
  drop constraint if exists memory_threads_place_pair_chk,
  drop constraint if exists memory_threads_partner_note_pair_chk;
alter table public.memory_threads
  add constraint memory_threads_place_pair_chk
    check ((place_cipher is null) = (place_nonce is null)),
  add constraint memory_threads_partner_note_pair_chk
    check ((partner_note_cipher is null) = (partner_note_nonce is null));

-- cover_path / cover_tile_path are DENORMALISED onto the parent on purpose.
-- Without them the timeline query reaches no photo at all: thumb paths live on
-- the child, so painting 50 covers is a second round trip before the prefetch
-- can even begin, and when cover_photo_id is null ("position 0 of each of
-- these 50 parents") PostgREST cannot express it without N+1. One trigger buys
-- one query and no embed.
--
-- Correlated scalar subqueries rather than the obvious `from lateral (...)`:
-- an UPDATE's target relation is not reliably visible to a LATERAL item in its
-- FROM list, and the cover choice has to read cover_photo_id off the very row
-- being written. In the SET list that reference is ordinary and always legal.
create or replace function public._memory_cover_sync()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare m uuid;
begin
  m := coalesce(new.memory_id, old.memory_id);
  update public.memory_threads t set
    cover_path = (select p.cover_path from public.memory_photos p
                   where p.memory_id = m
                   order by (p.id = t.cover_photo_id) desc, p.position asc limit 1),
    cover_tile_path = (select p.tile_path from public.memory_photos p
                   where p.memory_id = m
                   order by (p.id = t.cover_photo_id) desc, p.position asc limit 1),
    photo_count   = (select count(*)        from public.memory_photos where memory_id = m),
    last_photo_at = (select max(created_at) from public.memory_photos where memory_id = m)
  where t.id = m;
  return null;
end $fn$;
drop trigger if exists memory_photos_cover_sync on public.memory_photos;
create trigger memory_photos_cover_sync after insert or update or delete on public.memory_photos
  for each row execute function public._memory_cover_sync();

create or replace function public._memory_cover_pick_sync()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads t set
    cover_path = (select p.cover_path from public.memory_photos p
                   where p.memory_id = new.id
                   order by (p.id = new.cover_photo_id) desc, p.position asc limit 1),
    cover_tile_path = (select p.tile_path from public.memory_photos p
                   where p.memory_id = new.id
                   order by (p.id = new.cover_photo_id) desc, p.position asc limit 1)
  where t.id = new.id;
  return null;
end $fn$;
drop trigger if exists memory_threads_cover_pick on public.memory_threads;
create trigger memory_threads_cover_pick after update of cover_photo_id on public.memory_threads
  for each row execute function public._memory_cover_pick_sync();

-- ── Two nullable columns that must move together ───────────────────────────
-- photo_cipher set with photo_nonce null renders a completely blank black
-- screen today: the chip is gated on photoCipher alone
-- (memory_threads_screen.dart:727), photoPayload() needs both, so _bytes,
-- _error and _loading are all falsy and none of the three build branches fire.
-- Zero such rows exist; this makes that permanent.
alter table public.memory_threads
  drop constraint if exists memory_threads_photo_pair_chk;
alter table public.memory_threads
  add constraint memory_threads_photo_pair_chk
  check ((photo_cipher is null) = (photo_nonce is null)) not valid;
alter table public.memory_threads validate constraint memory_threads_photo_pair_chk;

alter table public.memory_threads
  drop constraint if exists memory_threads_state_chk;
alter table public.memory_threads
  add constraint memory_threads_state_chk
  check (state in ('proposed','accepted','archived','deletion_requested','deleted'));

-- ── REGRESSION FIX 1: NO ACTION FKs to auth.users ──────────────────────────
-- Verified live: memory_threads_delete_requested_by_fkey and _deleted_by_fkey
-- are both confdeltype='a' against auth.users, and rituals carries the same
-- pair. delete_my_account deletes auth.users; when the partner survives, the
-- couple survives, these rows survive, and the whole transaction aborts —
-- reopening the exact breakage 003400 closed. 003800's guard filters confrelid
-- in (profiles, couples), so an FK to auth.users was invisible to it.
alter table public.memory_threads
  drop constraint if exists memory_threads_delete_requested_by_fkey,
  drop constraint if exists memory_threads_deleted_by_fkey;
alter table public.memory_threads
  add constraint memory_threads_delete_requested_by_fkey
    foreign key (delete_requested_by) references public.profiles(id) on delete set null,
  add constraint memory_threads_deleted_by_fkey
    foreign key (deleted_by) references public.profiles(id) on delete set null;

alter table public.rituals
  drop constraint if exists rituals_delete_requested_by_fkey,
  drop constraint if exists rituals_deleted_by_fkey;
alter table public.rituals
  add constraint rituals_delete_requested_by_fkey
    foreign key (delete_requested_by) references public.profiles(id) on delete set null,
  add constraint rituals_deleted_by_fkey
    foreign key (deleted_by) references public.profiles(id) on delete set null;

-- ── REGRESSION FIX 2: proposer CASCADE destroys the partner's half ─────────
-- Verified live: memory_threads_proposer_fkey is confdeltype='c'. Deleting an
-- account hard-deletes every memory that person proposed — accepted ones
-- included, the surviving partner's own contributed photos with them, with no
-- consent, no 30 days, no notice. 003800's rule ("NOT NULL attribution →
-- CASCADE, deleting the person's own content is the right answer") is correct
-- for content one person owns and wrong for the one object in this app that by
-- design requires two people.
alter table public.memory_threads alter column proposer drop not null;
alter table public.memory_threads drop constraint if exists memory_threads_proposer_fkey;
alter table public.memory_threads
  add constraint memory_threads_proposer_fkey
    foreign key (proposer) references public.profiles(id) on delete set null;

-- The guard 006800 installed would have vetoed the SET NULL above and taken
-- account deletion down with it: the referential action runs as an ordinary
-- UPDATE, the BEFORE UPDATE trigger sees proposer go uuid → null, and
-- `is distinct from` raises 'proposer is immutable'. Nulling is now the one
-- permitted move, and it is one-way — a null proposer can never be given a
-- value, so nothing can claim authorship of an orphaned memory.
create or replace function public.memory_threads_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $fn$
begin
  if new.proposer is not null and new.proposer is distinct from old.proposer then
    raise exception 'proposer is immutable';
  end if;
  if new.couple_id is distinct from old.couple_id then
    raise exception 'couple_id is immutable';
  end if;
  if new.state = 'accepted' and old.state = 'proposed'
     and new.accepted_by = old.proposer then
    raise exception 'a proposal must be accepted by the other partner';
  end if;
  return new;
end $fn$;

-- memory_revisits: the API is deleted on the client in this same change, but
-- the TABLE stays until installed builds have rolled over. Build 20 is on the
-- handset and there is no update channel; dropping a table the shipped binary
-- still writes to turns a useless button into an error. Its CASCADE onto
-- profiles is what the widened guard below objects to, so neutralise that and
-- leave the corpse for a later migration. Zero rows, verified.
alter table public.memory_revisits alter column initiated_by drop not null;
alter table public.memory_revisits drop constraint if exists memory_revisits_initiated_by_fkey;
alter table public.memory_revisits
  add constraint memory_revisits_initiated_by_fkey
    foreign key (initiated_by) references public.profiles(id) on delete set null;

-- ── Storage reap ───────────────────────────────────────────────────────────
-- Deleting memory_photos rows leaves c.enc/t.enc/f.enc in the bucket forever
-- with nothing left that knows their paths. §5's copy promises the files are
-- erased; without this it is false.
create table if not exists public.storage_reap (
  bucket_id text not null, name text not null, queued_at timestamptz not null default now(),
  primary key (bucket_id, name)
);
alter table public.storage_reap enable row level security;   -- no policies: nobody but DEFINER
revoke all on public.storage_reap from anon, authenticated;

create or replace function public._memory_photo_reap()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  insert into public.storage_reap (bucket_id, name)
  values ('couple_intimate', old.cover_path), ('couple_intimate', old.tile_path),
         ('couple_intimate', old.full_path)
  on conflict do nothing;
  return old;
end $fn$;
drop trigger if exists memory_photos_reap on public.memory_photos;
create trigger memory_photos_reap before delete on public.memory_photos
  for each row execute function public._memory_photo_reap();

-- Honest limitation, matching what 003400 already does: removing the row from
-- storage.objects unlinks the object from the API but does not itself delete
-- the backing blob. The client removes paths through the Storage API on the
-- happy path (memory_confirm_delete's caller); this is the backstop for
-- crashes, cascades and dissolutions, and a service-role edge function should
-- eventually drain it through the API.
create or replace function public.reap_storage_objects()
returns void language sql security definer set search_path = public as $fn$
  with gone as (
    delete from storage.objects o using public.storage_reap r
     where o.bucket_id = r.bucket_id and o.name = r.name returning r.bucket_id, r.name)
  delete from public.storage_reap r using gone g
   where r.bucket_id = g.bucket_id and r.name = g.name;
$fn$;
revoke execute on function public.reap_storage_objects() from public, anon, authenticated;

-- ── Indexes ────────────────────────────────────────────────────────────────
-- memory_couple_state_idx (001400) and memory_threads_live_idx (006600) are
-- both btree(couple_id, state) — verified identical. One is pure write
-- overhead, and neither supports ORDER BY happened_on desc, which is the query.
drop index if exists public.memory_threads_live_idx;
drop index if exists public.memory_couple_state_idx;
create index if not exists memory_threads_timeline_idx
  on public.memory_threads (couple_id, happened_on desc) where state <> 'deleted';
create index if not exists memory_threads_anniversary_idx
  on public.memory_threads (couple_id, (extract(doy from happened_on))) where state = 'accepted';

-- ── Realtime ───────────────────────────────────────────────────────────────
-- Without this the headline multi-photo feature is silently non-live: the
-- gallery and "she added 3 photos" both need INSERT events on the child.
do $do$ begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public'
                    and tablename='memory_photos') then
    alter publication supabase_realtime add table public.memory_photos;
  end if;
end $do$;
-- DEFAULT replica identity, deliberately: 'f' on the parent is what made every
-- accept re-emit every column. The child's payloads are small either way, and
-- DELETE only needs the key.
alter table public.memory_photos replica identity default;

-- ── Purge ──────────────────────────────────────────────────────────────────
-- hardDelete only flips state to 'deleted' and its own comment says "so a
-- future purge job can vacuum these" (repository.dart:307). No such job
-- existed, while the UI promised "This cannot be undone".
create or replace function public.purge_deleted_memories()
returns void language sql security definer set search_path = public as $fn$
  delete from public.memory_threads
   where state = 'deleted' and deleted_at < now() - interval '30 days';
$fn$;
revoke execute on function public.purge_deleted_memories() from public, anon, authenticated;

do $do$ begin
  if exists (select 1 from pg_extension where extname='pg_cron') then
    if exists (select 1 from cron.job where jobname='purge-deleted-memories')
      then perform cron.unschedule('purge-deleted-memories'); end if;
    perform cron.schedule('purge-deleted-memories','17 3 * * *',
      $j$select public.purge_deleted_memories(); select public.reap_storage_objects();$j$);
  end if;
end $do$;

-- ── The widened guard ──────────────────────────────────────────────────────
-- Two misses in the original: auth.users was not in the confrelid list (which
-- is how 006600 got through), and CASCADE was never tested at all (which is
-- how proposer got through, and the guard then read as an endorsement).
do $do$
declare n int; d text;
begin
  -- confdeltype is "char", not text, and `text || "char"` has no unique
  -- operator — the cast is load-bearing, not decoration.
  select count(*), coalesce(string_agg(conrelid::regclass||'.'||conname||' ['||confdeltype::text||']', ', '), '')
    into n, d from pg_constraint
   where contype='f' and connamespace='public'::regnamespace
     and confrelid in ('public.profiles'::regclass,'public.couples'::regclass,'auth.users'::regclass)
     and (confdeltype = 'a'
          or (confdeltype = 'c'
              and conrelid in ('public.memory_threads'::regclass,
                               'public.memory_photos'::regclass,
                               'public.memory_revisits'::regclass)
              and confrelid <> 'public.couples'::regclass));
  if n > 0 then
    raise exception 'account deletion is unsafe: % foreign key(s): %', n, d;
  end if;
end $do$;
