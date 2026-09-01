# Memory Threads — Final Implementable Specification

Live re-verification performed for this document against `sopictusdonlvuezmfep`. Everything asserted below as "verified" was checked in this session; the raw results are quoted where they change a decision.

---

## 0. Rulings on the three critiques

**Accepted and folded in (no argument):** C1‑1 (400px cover upscale), C1‑2 (no path column → N+1), C1‑3 / C2‑C6 (shared 200‑object `DefaultCacheManager`), C1‑4 (ImageCache strong retention), C1‑5 (prefetch fires too late), C1‑6 (`getFileFromCache` is async), C1‑7 (no fling cancellation), C1‑8 (isolate per 20 KB + base64 round trip), C1‑9 (zoom layer never built), C1‑10 (CPU and network share a semaphore), C1‑11 (gallery opens at the wrong index), C1‑12 (403 has no owner), C1‑13 (epoch leak, stale memo), C1‑14 (`aspect` is an unused leak — column dropped), C2‑A1 (plain DELETE bypass), C2‑A2 (column grants beat trigger+GUC), C2‑A3 (`proposer` mutable → self‑accept), C2‑A4 (`proposer_fkey` CASCADE), C2‑A5 (cancel unarchives), C2‑B1 (plaintext mode uploads a cleartext JPEG), C2‑B2 (heal propagates it), C2‑B3 (AD does not bind containment), C2‑B4 (partner key unpinned; `keyWasReplaced` is the wrong signal), C2‑C1 (objects never deleted; no UPDATE policy), C2‑C2 (`couple_id` unchecked against parent), C2‑C3 (child table not in the realtime publication), C2‑C4 (bytea RPC params), C2‑C5 (ledger mismatch), C3‑1 (no notification is the real cause of 9/9), C3‑2 (PIN has no recovery), C3‑4 (no search), C3‑5 (queue is not persisted → silent loss), C3‑6 (PIN before an empty screen), C3‑7 (EXIF capture date).

**Verified live, quoted, because they are load-bearing:**

```
polname                       polcmd  using_expr
memory_threads_delete_member  d       (couple_id = (SELECT current_user_couple_id()))
grantee=authenticated  privileges=DELETE,UPDATE,SELECT,INSERT      -- C2-A1 confirmed
grantee=anon           privileges=SELECT

conname                                  ref          confdeltype
memory_threads_proposer_fkey             profiles     c            -- C2-A4 confirmed
memory_threads_delete_requested_by_fkey  auth.users   a            -- §1.4 regression confirmed
memory_threads_deleted_by_fkey           auth.users   a
memory_threads_couple_id_fkey            couples      c

storage.objects policies: intimate_select(r), intimate_insert(a), intimate_delete(d)
  -- no UPDATE policy: upsert:true 403s. C2-C1 confirmed.

couple_intimate.allowed_mime_types includes application/octet-stream   -- octet-stream WILL upload
couple_intimate.file_size_limit = 104857600
```

**Corrections to the critiques, one line each:**

1. **C2‑C5 is right that the ledger is disjoint, wrong about the consequence.** Verified: the ledger's top entries are `20260814005550 key_escrow`, `20260814000942 memory_threads_and_rituals_delete_columns`, and `couple_intimate.allowed_mime_types` already contains `application/octet-stream` — so 006400's *effect* is live under a different ledger name. Migrations here are applied by `apply_migration`, not `supabase db push`; the repo filenames are documentation. Nothing will be double-applied, but §10 test 13 ("sorts after 006700") is worthless and is replaced.
2. **C1‑9's alternative "cap `maxScale` at 2.0" is the wrong branch** — the full bytes are already in L2 at that moment, so the upgrade layer costs one decode and zero network; build it.
3. **C1‑15 is right in principle, wrong as a blanket rule** — reusing the unbounded 400px frame is better up to ~12 photos and worse above it; the spec branches on count rather than picking one.
4. **C3's "drop `forceDelete`" is rejected** — it is the only exit when the partner's account no longer exists; the RPC stays, the button is simply not in the main action row.
5. **C3's "question the PIN at all" is rejected** — F9 states it; the fix is *when* it is asked, not whether.
6. **C3's "a grid is the right default past 20 memories" is rejected** — search plus a year scrubber solves the finding problem; the rail is the feature's identity and stays.
7. **The original §5.6 `biometricOnly: true` is rejected** (C3‑2 is right) — the device credential is currently the *only* way in for someone who forgot their four digits; it stays until Forgot‑PIN ships, and then it stays anyway.
8. **The original §2.5 claim that "PIN entry buys ~1.5 s" is rejected as written** — `onUnlocked` fires *after* the typing; the prefetch moves to gate mount, with the privacy consequence written down.
9. **C3 is right that acceptance is gated too hard, wrong that authored acceptance is the problem** — it is demoted from gate to follow‑up, not cut.
10. **C1‑1's aside that `media_source.dart:78` claims 720px** is a stale comment against `Thumbnails._maxEdge = 400` (verified in `thumbnails.dart:27`); it affects nothing here but should be corrected in passing.

---

## 1. What the user sees

### 1.1 The first second — and the thing that actually matters

The screen is not where this feature fails. Verified: `supabase/functions/` contains exactly `care-notify`, `map-token`, `reach-notify`, `turn-credentials`; grep for `memory` across `supabase/functions` returns nothing. **A proposal fires no notification at all.** Nine proposals, two couples, zero acceptances, because the only way to discover one is to open a disguised app, pass the app lock, find the ninth tile in the Closer grid, and enter a PIN. That is a message posted into a locked drawer.

So the first second, in the order the user actually experiences it:

1. **A push arrives:** *"She proposed a memory."* No title, no photo, no preview — the content is encrypted and the server cannot render it anyway. Contentless push is not a limitation here, it is the correct design.
2. **The Closer grid shows a dot on the Memory Threads tile.** A count of `state = 'proposed' and proposer <> auth.uid()`, obtainable with `count: CountOption.exact, head: true` and no decryption — `state` and `proposer` are plaintext.
3. **The PIN gate.** With a **Forgot PIN** link (re-auth with the account password → `clearAppPin`). On a device with no memories yet, there is no PIN at all — it is created on first *write*, not first *open*.
4. **The timeline paints laid out, with text, dates, and correctly-sized empty cover frames, in the first frame.** Titles are already decrypted (one batched isolate hop, §3.6). Covers fill in.
5. **The pending memory is at the top, in a band, with one button: Accept.** One tap. "Add your side of it" is offered *after* it goes live.

Time-to-something-readable on a warm second open: one frame. Time-to-first-cover: one L1 disk read plus one inline decrypt, ~15–30 ms per cover, six covers in parallel-ish — under the 400 ms `kIndicatorDelay`, so no spinner. Time-to-first-cover on a genuinely cold device: bounded by the network chain in §12's closing note, roughly 700 ms–1.5 s, during which the layout is complete and only the pictures are missing.

### 1.2 Exploring

- Scroll the thread rail; a year scrubber on the right edge jumps to a year.
- A search field over the already-decrypted title/note map — substring, client-side, zero server cost.
- Tap a cover → gallery pager, opening **on the cover's own index**, underlay already warm.
- Pinch past 1.5× → the full-resolution layer mounts over the bounded one.
- Long-press an entry → the action sheet (three items in the normal case).
- `+` in the gallery → multi-select, straight into an existing memory.

---

## 2. Data model + SQL

### 2.1 The two decisions everything follows from

**The picture leaves the row.** Verified previously: 9 rows, all with a photo, `avg(octet_length(photo_cipher)) = 352,062`, `max = 1,579,965`. PostgREST renders `bytea` as `\x`+hex at two characters per byte, the client selected every column (`memory_thread_repository.dart:150`), and `relreplident = 'f'` means it re-ran on every realtime tick. Painting a list of titles moved megabytes.

**The disk cache holds ciphertext; only RAM holds plaintext.** The vault decrypts to `getTemporaryDirectory()` (`vault_media_cache.dart:118-125`) and clears in `dispose()` (`private_vault_screen.dart:290-294`) — but backgrounding is exactly when Android kills the process, so `dispose` often never runs. Ciphertext at rest is as safe as ciphertext in Postgres, and it lets `flutter_cache_manager` be reused verbatim.

**Caveat that must be stated, not buried (C2‑B4):** the couple key is derived by ECDH against a partner public key the *server hands out*, with no pin, no fingerprint, no out-of-band comparison anywhere in the codebase (`supabase_repository.dart:202-209`). "The server cannot see the picture" is therefore true against a passive server and unproven against an active one. §3.9 adds a TOFU pin, which is also the correct signal for §7.4's failure copy.

### 2.2 Storage layout

The couple id must be the first path segment — every policy tests `(storage.foldername(name))[1] = current_user_couple_id()::text`.

```
$coupleId/memory/$photoId/c.enc    cover,  1024px longest edge, JPEG q75, ~120 KB
$coupleId/memory/$photoId/t.enc    tile,    400px longest edge, JPEG q72,  ~20 KB
$coupleId/memory/$photoId/f.enc    full original, byte-for-byte what was picked
```

Three objects, not two. C1‑1 is correct that a 400px source under a full-bleed 16:10 cover is a 2.16× upscale on the first thing the user sees; and it is correct that raising the single object to 1024 makes the unbounded-decode argument collapse. Two derived objects resolves both: the cover is its own surface with its own bound, and `t.enc` is still shared unbounded between the gallery grid, the pager underlay, and (conditionally) the filmstrip. All three are produced from **one** decode in **one** isolate call (§3.4), so the extra object costs one `copyResize` and one ~120 KB upload per photo — roughly 3 % on top of a 4 MB original.

All uploaded as `application/octet-stream` (verified present in the live whitelist) with `cacheControl: '31536000'`, packed `nonce||mac||ct` via `packFull`.

**`upsert: true` is forbidden.** Verified: there is no UPDATE policy on `storage.objects` for this bucket, only `intimate_select`/`intimate_insert`/`intimate_delete`. A retry over an existing path must `.remove()` first.

### 2.3 Associated data — frozen wire contract

`crypto_core.dart:126-129` derives ONE key for all of Closer (`info: 'miles-closer-v1'`). All separation between features is the AD string. Changing one makes every existing row fail Poly1305.

**Existing, unchangeable:**
```
title  →  '$threadId'
note   →  '${threadId}_note'
photo  →  '${threadId}_photo'          legacy inline column, read path only
```

**New, frozen from first write. C2‑B3 is correct and this is now-or-never:** the AD must bind containment, not just identity. A per-photo AD authenticates nothing about which memory a photo belongs to, and `memory_id`, `cover_photo_id`, `visit_id` are all plaintext — an adversary with database write access can re-parent a photo into a different memory and every device accepts it because the tag still verifies.

```
place        →  '${threadId}_place'
partner note →  '${threadId}_pnote'
cover        →  '${memoryId}_${photoId}_cover'
tile         →  '${memoryId}_${photoId}_tile'
full         →  '${memoryId}_${photoId}_full'
caption      →  '${memoryId}_${photoId}_caption'
```

`position` is deliberately **not** in the AD: it changes on reorder, and folding it in would make every reorder a re-encrypt of three objects. The residual is that an adversary with write access can reorder a gallery. Accepted explicitly.

`photoId` is a client-side v4 UUID from `Random.secure` (`repository.dart:361-372`), minted before the insert so it can be AD. Nonce reuse is a non-issue: `_aead.encrypt` mints a fresh 24-byte nonce per call (`crypto_core.dart:190`).

### 2.4 Migration A — `memory_threads_redesign`

Apply via `apply_migration` (name: `memory_threads_redesign`). Mirror the file at `supabase/migrations/20260601006800_memory_threads_redesign.sql`.

```sql
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
create policy memory_photos_select_member on public.memory_photos
  for select using (couple_id = (select public.current_user_couple_id()));
create policy memory_photos_insert_member on public.memory_photos
  for insert with check (added_by = auth.uid()
    and memory_id in (select id from public.memory_threads
                       where couple_id = (select public.current_user_couple_id())));
create policy memory_photos_update_member on public.memory_photos
  for update using (couple_id = (select public.current_user_couple_id()))
          with check (couple_id = (select public.current_user_couple_id()));
-- Removing the MEMORY is dual-consent. Removing one photo you contributed is
-- an edit to your own contribution.
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

-- cover_path / cover_tile_path are DENORMALISED onto the parent on purpose.
-- Without them the timeline query reaches no photo at all: thumb paths live on
-- the child, so painting 50 covers is a second round trip before the prefetch
-- can even begin, and when cover_photo_id is null ("position 0 of each of
-- these 50 parents") PostgREST cannot express it without N+1. One trigger buys
-- one query and no embed.
create or replace function public._memory_cover_sync()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare m uuid;
begin
  m := coalesce(new.memory_id, old.memory_id);
  update public.memory_threads t set
    cover_path = p.cover_path, cover_tile_path = p.tile_path,
    photo_count   = (select count(*) from public.memory_photos where memory_id = m),
    last_photo_at = (select max(created_at) from public.memory_photos where memory_id = m)
  from lateral (
    select cover_path, tile_path from public.memory_photos
     where memory_id = m
     order by (id = t.cover_photo_id) desc, position asc
     limit 1
  ) p
  where t.id = m;
  -- The lateral yields no row when the last photo is removed; clear it.
  update public.memory_threads
     set cover_path = null, cover_tile_path = null, cover_photo_id = null,
         photo_count = 0, last_photo_at = null
   where id = m and not exists (select 1 from public.memory_photos where memory_id = m);
  return null;
end $fn$;
drop trigger if exists memory_photos_cover_sync on public.memory_photos;
create trigger memory_photos_cover_sync after insert or update or delete on public.memory_photos
  for each row execute function public._memory_cover_sync();

create or replace function public._memory_cover_pick_sync()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads t set
    cover_path = p.cover_path, cover_tile_path = p.tile_path
  from lateral (
    select cover_path, tile_path from public.memory_photos
     where memory_id = new.id
     order by (id = new.cover_photo_id) desc, position asc limit 1
  ) p where t.id = new.id;
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
  add constraint memory_threads_photo_pair_chk
  check ((photo_cipher is null) = (photo_nonce is null)) not valid;
alter table public.memory_threads validate constraint memory_threads_photo_pair_chk;

alter table public.memory_threads
  add constraint memory_threads_state_chk
  check (state in ('proposed','accepted','archived','deletion_requested','deleted'));

-- ── REGRESSION FIX 1: NO ACTION FKs to auth.users ──────────────────────────
-- Verified live: memory_threads_delete_requested_by_fkey and _deleted_by_fkey
-- are both confdeltype='a' against auth.users. delete_my_account deletes
-- auth.users; when the partner survives, the couple survives, these rows
-- survive, and the whole transaction aborts — reopening the exact breakage
-- 003800 closed. 003800's guard filters confrelid in (profiles, couples), so
-- an FK to auth.users was invisible to it.
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
-- eventually drain it through the API. Flagged in §11, not pretended away.
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
  select count(*), coalesce(string_agg(conrelid::regclass||'.'||conname||' ['||confdeltype||']', ', '), '')
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
```

`memory_revisits.initiated_by` is also CASCADE and is caught by the widened guard; §7.4 deletes that table's API entirely, so repoint or drop it in the same migration depending on which branch of §7.4 is taken.

### 2.5 Migration B — `memory_consent_rpcs`

C2‑A1 and C2‑A2 rewrite this section. The original's trigger + GUC is replaced by column privileges: PostgREST enforces column-level grants, SECURITY DEFINER functions run as owner and are unaffected, and there is no bypass flag to reason about. This also closes A3 for free.

```sql
-- Dual consent was enforced only in Dart. Verified live: authenticated holds
-- DELETE,UPDATE,SELECT,INSERT on memory_threads, memory_threads_delete_member
-- permits a hard row delete on any row in the couple, and
-- memory_threads_update_member permits writing ANY column. "Your partner must
-- confirm" was a client-side if (memory_threads_screen.dart:846-848) over a
-- policy that permitted the row to be written any way at all.
--
-- The back door: supabase.from('memory_threads').delete().eq('id', x) is a
-- hard delete — no transition, no trigger, no deleted_at, no 30-day window, no
-- partner. Seven RPCs on the front door do not close it.
drop policy if exists memory_threads_delete_member on public.memory_threads;
revoke select, delete on public.memory_threads from anon;
revoke delete, update on public.memory_threads from authenticated;

-- The grant list is the security boundary. It deliberately omits id, couple_id,
-- proposer, happened_on, state, accepted_by/at, archived_at,
-- delete_requested_by/at, deleted_by/at, photo_count, last_photo_at,
-- cover_path, cover_tile_path.
--
-- proposer's omission is not cosmetic. With it writable, A proposes M, sets
-- proposer = B's uuid (policy passes, couple_id unchanged), then calls
-- memory_accept — whose `proposer <> auth.uid()` now holds. A alone produces an
-- accepted memory attributed to B, with A's own text in the "she wrote" slot.
-- §7.1, the highest-value change in this document, rests entirely on that check.
grant update (title_cipher, title_nonce, note_cipher, note_nonce,
              place_cipher, place_nonce, cover_photo_id, visit_id)
  on public.memory_threads to authenticated;

-- The same door is open on the vault. 001400's do-loop created identical
-- *_delete_member policies for vault_items, afterglow_entries and
-- couple_dissolutions. Out of scope here, flagged in §11, and it is the same
-- one-line fix.

-- Same shape as claim_thumb (006200): SECURITY DEFINER, one row, inside the
-- caller's own couple, one transition each, actor asserted against auth.uid()
-- rather than taken as a parameter.

-- Accepting is the PARTNER's act. Notes are OPTIONAL — passing nulls is the
-- one-tap path, and §7.1's authored acceptance is offered afterwards, not as a
-- gate. Making the only transition running at zero more expensive is not a fix.
create or replace function public.memory_accept(
  p_id uuid, p_note_cipher bytea default null, p_note_nonce bytea default null)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  if (p_note_cipher is null) <> (p_note_nonce is null) then
    raise exception 'note cipher and nonce move together'; end if;
  update public.memory_threads
     set state='accepted', accepted_by=auth.uid(), accepted_at=now(),
         partner_note_cipher=coalesce(p_note_cipher, partner_note_cipher),
         partner_note_nonce =coalesce(p_note_nonce,  partner_note_nonce)
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state='proposed' and proposer is distinct from auth.uid();
  if not found then raise exception 'not yours to accept'; end if;
end $fn$;

-- Writing your side after the fact.
create or replace function public.memory_set_partner_note(
  p_id uuid, p_note_cipher bytea, p_note_nonce bytea)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads
     set partner_note_cipher=p_note_cipher, partner_note_nonce=p_note_nonce
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and accepted_by = auth.uid() and state in ('accepted','archived');
  if not found then raise exception 'not yours'; end if;
end $fn$;

create or replace function public.memory_set_state(p_id uuid, p_state text)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  if p_state not in ('accepted','archived') then raise exception 'bad state'; end if;
  update public.memory_threads
     set state=p_state, archived_at = case when p_state='archived' then now() else null end
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state in ('accepted','archived');
  if not found then raise exception 'not found'; end if;
end $fn$;

-- The state ALL NINE production rows are stuck in has no action at all today:
-- _actions() has exactly one 'proposed' branch and it requires !isMine, so the
-- Wrap renders empty for the person who created it.
create or replace function public.memory_withdraw(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads set state='deleted', deleted_by=auth.uid(), deleted_at=now()
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state='proposed' and proposer = auth.uid();
  if not found then raise exception 'not yours to withdraw'; end if;
end $fn$;

-- 'archived' is admitted: today Request delete is gated on accepted only
-- (screen.dart:837), so archiving permanently removes the only path to
-- deleting, and nothing in the UI says so. prior_state is stashed so that
-- cancelling an archived row does not silently unarchive it.
alter table public.memory_threads add column if not exists delete_prior_state text;
create or replace function public.memory_request_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads
     set state='deletion_requested', delete_prior_state=state,
         delete_requested_by=auth.uid(), delete_requested_at=now()
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state in ('accepted','archived');
  if not found then raise exception 'not found'; end if;
end $fn$;

-- Either partner may cancel. The repository's own comment already says exactly
-- this ("either can veto by cancelling", repository.dart:295-297) and the UI
-- contradicted it by showing Cancel only to the requester.
create or replace function public.memory_cancel_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads
     set state=coalesce(delete_prior_state,'accepted'), delete_prior_state=null,
         delete_requested_by=null, delete_requested_at=null
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state='deletion_requested';
  if not found then raise exception 'not found'; end if;
end $fn$;

-- THE dual-consent assertion. This one line is the whole guarantee and it
-- cannot live in the client.
create or replace function public.memory_confirm_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads
     set state='deleted', deleted_by=auth.uid(), deleted_at=now()
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state='deletion_requested' and delete_requested_by is distinct from auth.uid();
  if not found then raise exception 'only your partner can confirm this'; end if;
end $fn$;

-- The requester's escape hatch, on the SERVER's clock. The vault computes its
-- 14 days from DateTime.now() on the handset (private_vault_repository.dart:
-- 139-141), so a wrong device clock reaches expiry early or never — in a
-- codebase that already argues client clocks are untrustworthy (ServerClock).
--
-- Kept despite the argument that it is one verb too many: with proposer now ON
-- DELETE SET NULL, a sole surviving partner has no other exit.
create or replace function public.memory_force_delete(p_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
begin
  update public.memory_threads
     set state='deleted', deleted_by=auth.uid(), deleted_at=now()
   where id=p_id and couple_id=(select public.current_user_couple_id())
     and state='deletion_requested' and delete_requested_by = auth.uid()
     and delete_requested_at < now() - interval '14 days';
  if not found then raise exception 'not yet'; end if;
end $fn$;

do $do$ declare f text; begin
  foreach f in array array[
    'memory_accept(uuid,bytea,bytea)','memory_set_partner_note(uuid,bytea,bytea)',
    'memory_set_state(uuid,text)','memory_withdraw(uuid)','memory_request_delete(uuid)',
    'memory_cancel_delete(uuid)','memory_confirm_delete(uuid)','memory_force_delete(uuid)']
  loop
    execute format('revoke all on function public.%s from public, anon;', f);
    execute format('grant execute on function public.%s to authenticated;', f);
  end loop;
end $do$;
```

**C2‑C4, the client side of these RPCs:** bytea parameters go over the same text-input path as column inserts. A raw `Uint8List` JSON-encodes as an int array and binds as its ASCII decimal text — the exact bug documented at `closer_crypto.dart:130-141`. Every bytea RPC argument must be `bytesToBytes`/`bytesToBytea` hex, and §10 test 14 asserts it.

---

## 3. Media pipeline — exact constants and cache keys

### 3.1 What is reused by name

Verbatim: `MediaUrls.warm/cached/sign/refresh/clear` (`core/data/media_urls.dart:53-110,146`); `Thumbnails._resizeJpeg` incl. `bakeOrientation` and never-upscale; `MediaNormalize.toSendable`; `PhotoPickerService.pickMedia(limit:)` + `takeRejectedFormats()`; `CryptoCore.encryptBytesOffThread`; `kIndicatorDelay`; the warm-asymmetry and single-flight discipline of `media_viewer.dart:224-283`.

**Cannot be reused, plainly:** `NetImage` / `SignedImage` / `CachedNetworkImage` fetch a URL and hand bytes to the decoder — there is no hook between "downloaded" and "decoded" for a decrypt. `MemoryMediaCache` reimplements the *invariants*, which are: cache key is `'<bucket>/<path>'` never the signed URL; one shared decode width per object across surfaces; `memCacheHeight` / `ResizeImage.height` never set; derived objects file under different keys.

**Not reused, against the original spec:** `DefaultCacheManager`. Verified in `flutter_cache_manager-3.4.1/lib/src/config/_config_io.dart:14-15` — `stalePeriod ?? Duration(days: 30)`, `maxNrOfCacheObjects ?? 200` — and it is the same singleton every `CachedNetworkImage` in the app uses. Fifty covers plus tiles plus fulls competing with chat media in one 200-object bucket means ten minutes of chat scrolling evicts the entire feature, permanently. L1 gets its own store.

### 3.2 Cache layers and keys

```
L3  Flutter ImageCache      keyed by (provider identity, resize width)  — see §3.3
L2  plaintext LRU in RAM    key '${CryptoCore.keyEpoch}|$path'
      covers  16 entries    (~1.9 MB decoded each at 864px → 30 MB ceiling)
      tiles   96 entries    (~480 KB decoded each at 400px)
      fulls    3 entries
L1  ciphertext on disk      key 'couple_intimate/$path'
      CacheManager(Config('milesMemoryCipher',
        maxNrOfCacheObjects: 1500, stalePeriod: Duration(days: 90)))
```

L2 must return the **identical `Uint8List` instance**, never a copy: `MemoryImage.==` compares `bytes` by reference, so a copy silently doubles every decode and defeats L3. This is the subtlest rule in the file and it gets a test (§10.3).

`keyEpoch` is a new `static int` on `CryptoCore`, bumped inside `adoptPrivateSeed` and `deriveSharedKey`. The vault's cache is keyed by a per-*process* `_sessionId` (`vault_media_cache.dart:51`) and `adoptPrivateSeed` clears only `_sharedKey` — so after an escrow restore mid-session the vault keeps serving plaintext decrypted under the *old* key. The same fix should later be lifted into `VaultMediaCache`.

**C1‑13:** an epoch bump is a **clear**, not a key change. Changing the key alone leaves the old plaintext reachable in the LRU map forever, protecting correctness but neither memory nor the threat model.

### 3.3 ImageCache retention — the discipline that makes the rest true

`MemoryImage.obtainKey` returns `this`, and `ImageCache._cache` / `_liveImages` / `_pendingImages` hold that key. Every decrypted photo painted is therefore strongly reachable from `PaintingBinding.instance.imageCache` — up to 1000 entries / 100 MiB, **not device-scaled**, identical on a 2 GB IN2015.

Two consequences the original missed:

- **Evicting from L2 frees nothing** while the ImageCache still holds the key, and re-decrypting the same path yields a *new* `Uint8List` → a *new* `MemoryImage` → a second full decode and a second cache entry while the first sits resident.
- **`clear()` that drops only L2 leaves every painted photo alive in RAM behind the disguise cover.** §2.1's whole security argument is that only RAM holds plaintext and RAM is cleared at the boundaries; without this it is false.

So:

- **L2 owns and hands out `ImageProvider`s, not raw bytes.** `MemoryMediaCache.coverProvider(path)`, `.tileProvider(path)`, `.fullProvider(path, width)`. Nothing outside the cache constructs a `MemoryImage` over memory-thread bytes.
- On L2 eviction: `imageCache.evict(provider, includeLive: true)` for every provider derived from those bytes.
- On `clear()` / cover raise / sign-out / epoch bump: L2 clear **plus** `imageCache.clear()` **plus** `imageCache.clearLiveImages()`. L1 is ciphertext and is left alone.
- `main.dart`'s cover handler (~:268) calls this, not a screen's `dispose()` — the process is killed on background and `dispose` often never runs.

### 3.4 Derivation — one decode, three outputs

New in `thumbnails.dart`, alongside `forImage`:

```dart
const int kMemoryCoverMaxEdge = 1024;  // q75
const int kMemoryTileMaxEdge  = 400;   // q72  (== Thumbnails._maxEdge)

/// One isolate hop: decode once, emit both derivatives and the EXIF capture
/// date. Three separate calls would be three 12MP decodes at ~100ms each.
class DerivedImage { Uint8List cover, tile; DateTime? capturedAt; }
static Future<DerivedImage?> derive(Uint8List bytes);
```

The EXIF date is free here because the header is already parsed, and it is what makes §7.3's visit matching fire (§4.4).

### 3.5 Decode widths

| surface | provider | width |
|---|---|---|
| timeline cover | `ResizeImage(MemoryImage(coverBytes), width: coverPx)` | `min(1024, cardWidthDp * dpr)`, computed once per screen and memoized so every card shares one key |
| gallery grid tile | `MemoryImage(tileBytes)` | **unbounded** |
| pager underlay | `MemoryImage(tileBytes)` | **unbounded** — same instance, same key, one decode |
| pager full | `ResizeImage(MemoryImage(fullBytes), width: viewportPx)` | `(MediaQuery.sizeOf(ctx).width * dpr).round()` |
| pager neighbour precache | same | **identical** `viewportPx` |
| zoom layer | `MemoryImage(fullBytes)` | **unbounded**, mounted above `kZoomUpgradeScale` |
| filmstrip | `photoCount <= 12` ? `MemoryImage(tileBytes)` : `ResizeImage(…, width: kFilmstripDecodePx)` | unbounded / 138 |

Unbounded for the 400px tile is the rule from `media_source.dart:80` (`tileDecodeWidth => hasThumb ? null : kTileDecodePx`): the object is its own bound, so grid tile and pager underlay are one decode of one instance. The cover is a different object on a different screen and never cross-fades with them, so it does not share and does not need to.

`height` is never passed to any provider anywhere. `BoxFit.cover` shapes.

**The zoom layer must actually be built.** Verified: `grep -rn "kZoomUpgradeScale\|kZoomRevertScale" lib/ test/` returns three hits in `media_decode.dart` and one in `decode_identity_test.dart` asserting they are ordered — **zero widget call sites**. Pinching today magnifies a viewport-width bitmap 5×. Here the full bytes are already in L2 at that moment, so the upgrade costs one decode and no network: mount an unbounded `MemoryImage(fullBytes)` above 1.5×, unmount below 1.2×. Wire the same layer into `media_viewer.dart` while you are there.

Add to `media_decode.dart`, and fix the stale "already ~720px" comment at `:78` of `media_source.dart` in the same commit.

### 3.6 Decrypt — inline below the threshold, raw bytes above it

`crypto_core.dart:163-165` already states the rule for encrypt:

```dart
// Small payloads cost more to ship across the boundary than to encrypt.
if (bytes.length < 256 * 1024) { return encryptBytes(bytes, associatedData: associatedData); }
```

The original applied that to encrypt and ignored it for decrypt. Tiles (~20 KB) and covers (~120 KB) are both under it: XChaCha20-Poly1305 over 120 KB is well under a millisecond, while `compute()` spawns a fresh isolate per call — tens of milliseconds on an IN2015 plus two copies. Prefetching 24 covers as 24 `compute()` calls would be slower than doing them inline.

- **Tiles and covers decrypt inline on the UI isolate.**
- **Fulls go off-thread through a new `CryptoCore.decryptBytesOffThread(Uint8List packed, {String? associatedData})`**, mirroring `encryptBytesOffThread:152-170`, taking `packFull` output **directly**. It must not go through `EncryptedPayload`, whose fields are base64 *strings* — reusing `vault_media_cache.dart:22-40`'s shape would base64-encode every downloaded blob to build the request and decode it inside the isolate: +33 % allocation and two full passes over a 4 MB original per view. Use the new function in `VaultMediaCache` too.
- The zero-nonce / zero-MAC legacy branch (`crypto_core.dart:139-140`) is preserved on the read path.

### 3.7 The work queue — fling cancellation

The original had no velocity gating and no cancellation. `media_viewer.dart:229-231`'s single-flight guard is a *pager* guard; a grid has 50 simultaneously-building cells. Flinging from memory 1 to 50 starts ~45 jobs in `initState`, ~40 of them already recycled, and they complete in enqueue order — the six tiles actually on screen finish **last**, so the user stares at grey for a second on a device that already had every byte on disk.

`MemoryDecodeQueue`:

- concurrency **2**;
- every job carries `bool Function() isWanted`, re-read at **dequeue** time, not captured — the same "re-read rather than captured" discipline as `media_viewer.dart:260-262`, applied to a grid;
- a job whose index is now outside the visible range ±4 is dropped, not run;
- cells register interest and are notified; they do not own the work;
- every failure is swallowed and logged, never surfaced as a frame.

### 3.8 403 has an owner

`MediaUrls.refresh`'s doc comment names the case exactly:

> "this handset's clock is simply wrong, and a phone that is an hour fast hands out URLs it believes are fresh and the server believes are dead"

`_PhotoPage._onImageFailed` is `CachedNetworkImage.errorWidget` plumbing and is unavailable here. Without an owner, a clock-skewed phone renders every memory as `MediaMissing` with the copy *"the picture didn't make it"* — a flat lie that will make someone believe their photos are gone.

The retry lives in `MemoryMediaCache`'s fetch leg: on 401/403 from `getSingleFile`, call `MediaUrls.refresh(bucket, path)` **once** and retry. Only a 404 classifies as `MediaMissing`. A 403 surviving one refresh is a distinct transient state with its own copy.

### 3.9 Refusals and pinning

**Never upload without a key.** `encryptBytes` with `_sharedKey == null` returns `base64Encode(bytes)` with a 24-zero nonce and 16-zero MAC (`crypto_core.dart:176-186`); `packFull` then base64-*decodes* it, so the uploaded object is literally `24 zero bytes ‖ 16 zero bytes ‖ the raw JPEG` — a cleartext photo behind a shareable signed URL. `deriveSharedKey` nulls `_sharedKey` on three silent paths (legacy placeholder, base64 failure, length ≠ 32) and `ensureSharedKey` guards only the first. Today's blast radius is one `bytea` column; making the queue a process singleton that outlives its screen widens it to the CDN.

```dart
// In the upload path, not in the caller.
final k = await CryptoCore.exportSharedKeyBytes();
if (k == null) throw StateError('no couple key — refusing to upload');
// And, belt and braces, after packFull:
assert(!packed.take(40).every((b) => b == 0));
if (packed.take(40).every((b) => b == 0)) throw StateError('refusing to upload cleartext');
```

The same guard runs in `memory_heal.dart`. Without it, heal-on-read is a *propagation* mechanism rather than a remediation: `decryptBytes` short-circuits on `_isLegacy` and returns plaintext with no key at all, so the one production cleartext row would heal successfully in plaintext mode, re-upload as cleartext, and then null the original column — erasing the evidence.

**Pin the partner key (TOFU).** On the first successful decrypt, store `sha256(partnerPub)` in `FlutterSecureStorage`. A later mismatch is simultaneously the MITM alarm and the correct per-partner basis for §7.4's permanent-failure copy. This replaces `SupabaseRepository.keyWasReplaced` for that purpose — it is set by comparing **my own** previously published key to my current one (`:185-186`), so it detects *my* reinstall and can never observe hers, which means the original's plan to persist it was persisting the wrong bit.

### 3.10 Cold and warm open, honestly

**Warm (every open after the first, L1 full, L2 empty):** on **gate mount** — not `onUnlocked`, which fires after the typing has already elapsed — start the metadata query, then `MediaUrls.warm('couple_intimate', first24CoverPaths)` (one `createSignedUrls` call), then a bulk L1→L2 pass for those 24. This is stated as a deliberate privacy trade: ciphertext for the couple's memories is pulled onto the device before the local gate is satisfied. It is defensible — RLS is scoped to the session, not the PIN, and the bytes are useless without the key, which is already in secure storage — but it is a decision, not an oversight. Result: warm-in-~150 ms, not instant. Biometric unlock is ~400 ms, so the window is smaller than the original claimed even after this fix.

**The metadata query carries no pictures and reaches the cover in one round trip:**

```dart
.select('id,proposer,title_cipher,title_nonce,note_cipher,note_nonce,'
        'happened_on,state,accepted_by,accepted_at,archived_at,created_at,'
        'delete_requested_by,delete_requested_at,delete_prior_state,'
        'cover_photo_id,cover_path,cover_tile_path,photo_count,last_photo_at,'
        'visit_id,place_cipher,place_nonce,partner_note_cipher,partner_note_nonce')
```

~50 rows × a few hundred bytes ≈ **40 KB**, against 14.1 MB for twenty today. `cover_path` is on the row because of the denormalising trigger, so there is no second query and no N+1 for the null-cover case.

**Titles decrypt in one isolate hop** for all rows at once, returning a `Map<String,String>`, memoized on `(keyEpoch, threadId, cipherHash)` — **not** `(keyEpoch, threadId)`, because `memory_accept` writes `partner_note_cipher` and realtime delivers that UPDATE; a memo keyed without the ciphertext would hide the partner's note until process restart. Today each `_MemoryCard` decrypts in its own `initState` on the main isolate and re-runs on `didUpdateWidget`.

**Realtime becomes a delta.** Replace `.stream()` with a `RealtimeChannel` `postgres_changes` subscription applying INSERT/UPDATE/DELETE into an in-memory list. The current `.map()` closure calls `fromJson` on every row on every emission, which with `relreplident='f'` means one partner tapping Accept re-decodes twenty photos on both devices.

**A miss paints `MilesColors.surface2`, not a spinner** — the same placeholder `NetImage` uses. Any indicator is gated on `kIndicatorDelay` (400 ms) **and** on "nothing has painted yet". Fades: in 150 ms, out `Duration.zero`; the 1000 ms default fade-out composites two frames per recycled cell for a full second while scrolling.

**What is not free:** a first-ever open on a cold device with 50 memories moves ~6 MB of covers, not ~1 MB — that is the honest cost of fixing the upscale, and it makes the prefetch story materially worse rather than being absorbed. Mitigation: warm only the **first 24** covers, and warm the rest as entries approach the viewport. The user sees a complete laid-out timeline with text, dates, and correctly-sized frames immediately, and the first screenful of pictures over roughly a second on a slow link.

### 3.11 Quality

`propose_memory_screen.dart:64-67` picks with `imageQuality: 85` and no `maxWidth` — re-encoding lossily while keeping full pixel dimensions, the worst of both. The new path sends the picked bytes **byte-for-byte untouched** to `f.enc`, per `PhotoPickerService.pickMedia`'s stated contract. Only formats the pipeline cannot handle go through `MediaNormalize.toSendable`. Cap 40 MB per photo (bucket limit is 104857600, verified).

Full-resolution decode is bounded at viewport width; today `Image.memory(_bytes!)` (`screen.dart:949`) and the 180px preview (`propose_memory_screen.dart:184-189`) both decode a 12 MP photo at source resolution — ~48 MB of raster per view on the low-end targets.

---

## 4. Multi-select upload

### 4.1 What is copied from chat, and what is not

Copied from `ChatSendQueue`: process singleton so an upload survives the screen that started it; `_pump()` oldest-first with the slot refilled in `finally`; a failure sets `status = failed` and **keeps** the item; `notifyListeners()` once per pick; `clear()` on sign-out.

**Not copied — `albumId`.** `chat_send_queue.dart:145` mints one because chat rows are flat and grouping must be inferred. Here the parent `memory_id` *is* the album: grouping is a foreign key, already correct, already indexed. An `albumId` would be a second, weaker source of truth for a fact the schema already states.

**Not copied — the shared semaphore.** `_maxInFlight = 3` holds the slot across the *entire* `_run`, and the work inside it is a 12 MP decode + resize + two encodes + encrypt. Three slots means three image-processing isolates on a 2-core handset, while the singleton keeps running as the user navigates back to a timeline that is itself decrypting covers. Split it: `_maxNetInFlight = 3`, `_maxCpuInFlight = 1`, the CPU semaphore held only around `Thumbnails.derive` + encryption. The uplink stays saturated because uploads are the long pole, and exactly one core is ever burning on image work. Chat has this bug too; fix the pattern here.

**Not copied — the absence of persistence.** Verified: `grep -rn "Hive|SharedPreferences|persist|restore" lib/features/chat/chat_send_queue.dart` returns **nothing**; state is `final List<PendingSend> _pending = []` at `:81`. Chat gets away with it because a failed message is visible in the thread you are staring at. A memory upload is a background batch on a screen you have left — and this app *invites* the kill, because the disguise cover is raised on background. Twelve Lisbon photos, backgrounded to answer a message, process killed: the memory exists with the three that finished and **nothing anywhere says the other nine were lost**, because §4.2's write order guarantees a lost photo leaves no trace at all. That turns multi-select from a capability into a 12× liability.

`MemoryPhotoQueue` persists `(localPath, memoryId, photoId, position, status)` to `FlutterSecureStorage` on enqueue and on every status change, rehydrates and resumes on next launch, and surfaces itself **on the timeline entry**: *"3 of 12 photos uploaded · Retry"*, sourced from the queue, not from the row.

### 4.2 Per-photo write order

Strictly **cover → tile → full → row**, so a `memory_photos` row is never visible without its media.

```dart
final photoId  = _uuid();                                   // Random.secure
final norm     = await MediaNormalize.toSendable(file);
final bytes    = await norm.readAsBytes();
if (bytes.length > 40 * 1024 * 1024) throw TooBig();

await _cpu.acquire();                                       // _maxCpuInFlight = 1
final d = await Thumbnails.derive(bytes);                   // one decode → cover+tile+exif
final packedCover = packFull(await CryptoCore.encryptBytesOffThread(
    d.cover, associatedData: '${memoryId}_${photoId}_cover'));
final packedTile  = packFull(await CryptoCore.encryptBytesOffThread(
    d.tile,  associatedData: '${memoryId}_${photoId}_tile'));
final packedFull  = packFull(await CryptoCore.encryptBytesOffThread(
    bytes,   associatedData: '${memoryId}_${photoId}_full'));
_cpu.release();

_refuseIfCleartext(packedCover); _refuseIfCleartext(packedTile); _refuseIfCleartext(packedFull);

await _put('$coupleId/memory/$photoId/c.enc', packedCover);   // upsert: false, always
await _put('$coupleId/memory/$photoId/t.enc', packedTile);
await _put('$coupleId/memory/$photoId/f.enc', packedFull);

try {
  await _c.from('memory_photos').insert({ /* couple_id omitted — trigger derives it */ });
} catch (_) {
  await _remove(['…/c.enc', '…/t.enc', '…/f.enc']);           // compensating
  rethrow;
}
```

`upsert` is never true — verified, there is no UPDATE policy on `storage.objects` for this bucket, so it 403s. A retry over an existing path `.remove()`s first.

Atomicity honestly degrades from one operation to four, and a crash between them leaves orphaned objects the reap job never learns about (there is no row to trigger on). The vault already lives with exactly this shape.

### 4.3 The composer's optimistic grid

Tiles paint the local file while uploading, both branches bounded at a fixed tile edge:

```dart
const tileEdge = 112.0;
Image.file(File(local), fit: BoxFit.cover, cacheWidth: (tileEdge * dpr).round())
```

Per-tile states are **scrims over the picture**, never grey squares: sending = 45 % black + a thin progress arc; failed = red scrim + retry glyph, tap to retry, long-press to discard.

Picker: `PhotoPickerService.pickMedia(limit: 30)`. Videos are filtered out with a named reason (§11), and `takeRejectedFormats()` is drained into a one-line note ("2 HEIC photos couldn't be converted on this phone") rather than failing silently at upload.

`SecureScreen.setSecure()` on the composer — verified absent today, and it displays both the chosen photos and the typed title.

### 4.4 The date the user should not have to type

Verified: `grep -rn "exif|Exif|DateTimeOriginal|lastModified" lib/ --include=*.dart` returns **nothing** — no EXIF anywhere in the app, though `image: ^4.9.1` is already a dependency. Meanwhile the composer defaults `happened_on` to today. Someone uploading twelve Lisbon photos in August files them under August: wrong on the timeline, wrong for "on this day" forever, and — critically — §7.3's visit matching **never fires**, because the range check runs against a date the user had to guess by hand.

`Thumbnails.derive` already parses the header, so it returns `capturedAt` for free. `happened_on` defaults to the **earliest** picked photo's `DateTimeOriginal`, falling back to file mtime, and stays editable. The visit suggestion renders inline the moment it resolves: *"During your Lisbon trip, 12–19 Mar."* That one default is what makes the best idea in the document actually work. Treat mtime as the common case — some Android gallery providers strip EXIF, and this is unverified on the target handsets.

### 4.5 Adding photos later

`memory_photos_insert_member` requires only `added_by = auth.uid()` inside the couple, so either partner adds to any memory at any time. `last_photo_at` and `photo_count` on the parent let the timeline surface "she added 3 photos to *Lisbon*". This is the thing that makes it a thread rather than a post.

---

## 5. Dual-consent delete state machine

### 5.1 The machine

```
                      withdraw (proposer only)
     ┌──────────────────────────────────────────────┐
     │                                              ▼
  proposed ──accept (partner only, one tap)──► accepted ◄──unarchive──► archived
                                                   │  ▲                     │
                              request_delete ──────┤  │                     │
                                    (either)       │  └── cancel (EITHER,   │
                                                   │      restores prior) ──┤
                                                   ▼                        │
                                          deletion_requested ◄──────────────┘
                                             │           │
              confirm (the OTHER partner) ───┤           ├─── force (requester, ≥14d server time)
                                             ▼           ▼
                                                deleted ──30d cron──► row + objects gone
```

Every transition is a SECURITY DEFINER RPC. `authenticated` holds no table-level UPDATE and no DELETE at all. The client cannot reach a lifecycle column with any request it can construct.

Dead transitions closed, each against a specific line:

| gap | today | now |
|---|---|---|
| a proposer's own pending memory has zero actions — **the state all 9 production rows are in** | `_actions()` renders an empty `Wrap` (`screen.dart:821-850`) | `memory_withdraw` |
| archived cannot be deleted | Request delete gated on `accepted` (`:837`) | RPC accepts `accepted` or `archived` |
| only the requester can cancel | `:843-845`, contradicting `repository.dart:295-297` | either partner |
| cancelling an archived row silently unarchives it | — | `delete_prior_state` restores it |
| unarchive has no error handling or busy guard | inline `await`, no try/catch (`:834-836`) | same path as every sibling |
| `deleted` badge and border are unreachable code | filtered at `:152`/`:182`, rendered at `:778-802` | branch deleted |
| 14 days from the handset clock | vault does this (`private_vault_repository.dart:139-141`) | Postgres `now()` in the RPC; `ServerClock.now()` only decides whether to *show* the button |
| a plain DELETE bypasses all of it | verified live | policy dropped, privilege revoked |
| a self-accept via a `proposer` rewrite | verified reachable | column not grantable |

### 5.2 The action matrix as a pure function

```dart
/// Extracted so it is testable without a widget, a session or a network. The
/// equivalent logic in the vault (private_vault_screen.dart:206-246) is a
/// switch inside an async button handler and has no test.
enum MemoryAction { withdraw, accept, addMyNote, archive, unarchive, requestDelete,
                    cancelDelete, confirmDelete, forceDelete, addPhotos, setCover }

Set<MemoryAction> actionsFor({
  required MemoryState state,
  required bool iAmProposer,
  required String? deleteRequestedBy,
  required DateTime? deleteRequestedAt,
  required String me,
  required DateTime serverNow,     // ServerClock.now(), injectable
});
```

| state | proposer / requester | the other partner |
|---|---|---|
| `proposed` | withdraw | **accept** (one tap) |
| `accepted` | addPhotos, setCover, archive, requestDelete | same, plus addMyNote if accepter |
| `archived` | unarchive, requestDelete | same |
| `deletion_requested` < 14 d | cancelDelete | confirmDelete, cancelDelete |
| `deletion_requested` ≥ 14 d | cancelDelete, **forceDelete** | confirmDelete, cancelDelete |

**The UI exposes three, not eleven.** The card shows no chips at all. Long-press opens a sheet whose top section is Accept / Delete / Take it back as applicable; archive, set-cover and add-note live below a divider; `forceDelete` never appears in the sheet — it appears only inside the consent band, only after 14 days, only for the requester. Eight verbs is more lifecycle than this object has *in the UI*; it is exactly the right amount on the server.

### 5.3 How it reads

A memory in `deletion_requested` gets no red border and no badge. It gets a **band pinned to the top of the entry**, in the surface's warning tone, addressed to whoever is reading:

> **She asked to delete this.** *Confirm and it's gone for both of you — the encrypted files are erased within 30 days.*
> `[ Keep it ]  [ Delete it ]`

and on the requester's phone:

> **You asked to delete this.** *Waiting for her. You can delete it yourself from 28 Aug.*
> `[ Never mind ]`

The date is computed from `deleteRequestedAt + 14d`, not "in 14 days". Visible state, so neither partner has to remember they asked.

The copy is now true. Today's dialog says "Permanently delete this memory? This cannot be undone." (`screen.dart:559`) while `hardDelete` only flips a column and the ciphertext sits in the row forever. With the purge cron *and* the reap table, "within 30 days" is accurate — and it says *within 30 days* rather than *immediately*, because that is what happens.

---

## 6. UI spec

### 6.1 The diagnosis, mechanically

- **"ugly line up"** — no single content inset. The date row is `Row([emoji, SizedBox(8), date, Spacer, badge])` (`:674-689`) while title and note start at the container's 18px padding (`:663`), so the emoji's optical left edge and the title's disagree by ~26px. Nothing shares a baseline grid.
- **"not well maintained"** — two encodings of one fact: a border tint (`:770-781`) *and* a badge (`:783-819`); plus a chip row whose contents change size per state, so no two cards are the same height for the same reason.
- **"not professionally designed"** — the photo, the only thing a memory is about, is a 12px text pill reading "View photo" (`:727-761`).

### 6.2 The timeline

A **thread**, literally: a 1 px hairline at `x = 28` running the full scroll height, with each memory hanging off a node.

```
🔍 search                                          ← collapses on scroll down
2025 ────────────────────────────────────────────  ← pinned SliverPersistentHeader   ┃2026
                                                                                     ┃2025
 ●   ┌──────────────────────────────────────────┐                                    ┃2024
 │   │            [ cover photo ]        ⬚ 1/12 │  16:10, radius 20                  ┃  ← scrubber
 │   └──────────────────────────────────────────┘
 │   14 August · a year ago today                   accent, 11/w600
 │   The night the power went out                   17/w600, ivory
 │   We ate everything in the fridge by candle…     13/1.5, 2 lines, clamped
 │   ⌖ Lisbon · during your March trip              11, muted, only if set
 │
 ●   ⋮
```

Rules that make it line up:

- **One content inset.** Everything right of the thread shares left edge `x = 56`: date, title, note, place, cover. No emoji in the flow.
- **One vertical rhythm.** cover → 12 → date → 6 → title → 6 → note → 10 → place. Four gaps, three values.
- **State lives in the node, and only there.** Hollow ring = proposed. Filled = accepted. Filled at 40 % = archived. Filled warning-tone, with the band above, = deletion_requested. No border tint, no badge, no chips on the card.
- **No action chips.** Tap opens the gallery; long-press opens the sheet.
- **A memory with no photo is not a broken card.** No cover, title lifted to 20/w600, note unclamped — a text entry that looks deliberate.
- **Search** over the already-decrypted title/note map: substring, client-side, zero server cost, no index, no new column. Without it, finding "the Lisbon bakery one" at memory 50 is thirty seconds of thumb-scrolling and at 200 it is unusable, and the state tabs do not help because they filter state, not content.
- **The year rail is a scrubber**, not a label — drag to jump.
- **Tabs:** Thread / Pending / Archive. Pending exists because nine of nine production rows are stuck there.

**"On this day"** pins above the first entry when any accepted memory shares today's day-of-year. Pure client arithmetic over rows already loaded.

> **Three years ago today** · *The night the power went out* →

`couples.anniversary_date` is NULL for all 9 couples, so anything built on that column has no data — `happened_on` is the only real anniversary source in this app.

### 6.3 Gallery

Mechanics lifted from `media_viewer.dart`:

- `PageView` with `allowImplicitScrolling: true` — exactly ±1 built.
- `physics: _zoomed ? NeverScrollableScrollPhysics() : PageScrollPhysics()` — without it the gesture arena resolves pan-vs-page wrongly 100 % of the time, because `kTouchSlop` 18px beats `kPanSlop` 36px.
- **Thumbnail as an underlay layer, not a placeholder** — a `Stack` with the decrypted tile below the decrypted full, both underlay fades `Duration.zero`. A slow full shows a soft-but-correct picture, never black; a *failed* full draws the retry over the underlay rather than replacing it.
- Hero mounted unconditionally with an offstage tag for non-current pages — conditioning it changes the widget type at that slot and remounts the element, restarting a finished decode.
- Filmstrip taps use `jumpToPage`, not `animateToPage`.
- `_DelayedSpinner` at `kIndicatorDelay`, only when nothing has painted.
- **Opens at the cover's index**, not 0. Opening at 0 when `cover_photo_id` points at position 5 flies the Hero into a *different* photograph, onto a page whose tile was never warmed — a black underlay and a spinner in the exact moment the design most wants to feel instant.
- **The memory's non-cover tile paths are signed and pulled to L1 as ciphertext when the entry scrolls into the viewport**, not when it is tapped — §3.7's distance-2/3 tier applied to the gallery's entry point.
- Warm asymmetry inside the pager: distance 1 decrypted and decoded; distances 2–3 pulled to disk as ciphertext only.
- Long-press a filmstrip cell → *Make this the cover* / *Remove* (own photos only). `+` top-right runs the same multi-select flow into this memory.

### 6.4 The PIN

- **Not asked on an empty feature.** Created on first *write* or first open of a non-empty list. A new user currently invents and memorises four digits with no explanation of what they protect or what happens if they forget, and is rewarded with an empty screen.
- **Confirm-entry on setup.** Today you type four digits once and that is your PIN forever (`screen.dart:117`, `_needsSetup`).
- **Forgot PIN** — re-authenticate with the account password (the session already has it), then `clearAppPin` and set a new one. Verified: `clearAppPin` (`memory_pin_gate.dart:50`) has **zero call sites** and there is no "forgot" affordance anywhere in the feature. Without this, the only escape from a forgotten PIN is reinstalling — which per §7.4 destroys the shared key and permanently locks every memory **on both phones**. The PIN gap and the key-loss gap compound into total data loss, and the original treated them as separate sections.
- **6 digits and `_pinLength`/dot-count alignment ship in the same commit as Forgot PIN, not before.** The file's own doc claims 6 at `:5-6` while `:22` and `screen.dart:104` use 4.
- **`biometricOnly: true` is not added.** The original wanted it because the device credential satisfies the feature gate so the memory PIN is never asked. That is currently the *only* way in for someone who forgot their digits; removing it before Forgot PIN exists brick the feature, and after Forgot PIN exists it buys nothing worth the churn.
- `SecureScreen.setSecure()` on the PIN gate and the composer — verified applied only on the list (`:312`) and viewer (`:898`).

### 6.5 Empty states — three, not one

Today there is one (`:419-446`), and the unreadable case falls into it — precisely the failure `closer_load_result.dart:5-14` was written to prevent: *"an empty vault and a vault whose every row failed to decrypt rendered identically — and to the person looking at it, 'empty' reads as 'my data is gone'."*

1. **Never used one.** The rail drawn empty with a single hollow node: *"You write your side. She writes hers. Both stay."* Primary action: Propose. (Not *"she decides whether it goes on"* — that framing makes the partner a gatekeeper on your memory, and it is the framing that produced nine stuck rows.)
2. **Filtered empty.** *"Nothing archived."* No illustration, no call to action.
3. **Nothing could be opened.** `result.unreadableMessage` (`closer_load_result.dart:29-43`), which today has **zero call sites** in this feature — the repository counts unreadable rows and the screen reads only `result.items`, so failures vanish silently. Wired, plus a *Set up recovery* action.

### 6.6 A permanently-undecryptable row

Two places print the raw exception today: `_error = 'Could not decrypt: $e'` on the card (`:502`, rendered red at `:698-705`) and the identical string full-screen (`:913`). A MAC failure reads *"Could not decrypt: SecretBoxAuthenticationError: SecretBox has wrong message authentication code (MAC)"*. Stream errors dump `PostgrestException.toString()` to the screen (`:377-382`).

Classification moves to **where the decrypt happens**. Today the unreadable counter only increments when `fromJson` throws a bytea parse error, while decryption happens later and lazily per widget — so a MAC failure is never counted at all.

```dart
sealed class MemoryFailure {}
class KeyNotYetShared extends MemoryFailure {}   // StateError, crypto_core.dart:219
class KeyGoneForever  extends MemoryFailure {}   // SecretBoxAuthenticationError
class KeyMismatch     extends MemoryFailure {}   // TOFU pin mismatch (§3.9)
class MediaTransient  extends MemoryFailure {}   // 403 surviving one refresh
class MediaMissing    extends MemoryFailure {}   // 404 only
```

The entry **stays on the thread** — date, node, place intact — with the cover replaced by a muted panel:

- **`KeyNotYetShared`:** *"**Waiting for your partner.** This opens by itself once she's opened Closer on her phone."* No destructive action. Retries silently on the next `ensureSharedKey`.
- **`KeyGoneForever`:** *"**Locked to an old install.** This was encrypted with a key that was on your phone before you reinstalled. It can't be opened here — or on hers."* `[ Set up recovery ]` `[ Replace the photo ]`. The "or on hers" is the fact, not softening: `ensureSharedKey` re-fetches the partner's *currently published* key on every call and re-derives, and `publishMyPublicKey` upserts over the old one, so one partner's reinstall kills the history on both devices. Telling them to ask her to open Closer would be advice that cannot work. *Set up recovery* is `KeyEscrow.backup` — prospective only, it can only wrap a seed that still exists.
- **`KeyMismatch`:** *"**Something changed on her end.** The key this was locked with isn't the one her phone is publishing now."* This is the honest MITM/reinstall signal, and it is per-partner, which `keyWasReplaced` structurally cannot be.
- **`MediaTransient`:** *"**Couldn't reach this photo.** Try again."* — never the missing-file copy, because a phone with a skewed clock would otherwise be told its photos are gone.
- **`MediaMissing`:** *"**This photo's file is missing.** The memory is fine; the picture didn't make it."*

**Nothing renders `$e` anywhere.** §10.9 asserts it.

---

## 7. The conceptual expansion

**What a memory is:** the only object in this app that cannot exist unless two people agree it happened, and it is never finished.

Live evidence of how well the current design achieves that: **9 rows, 2 couples, 2 distinct proposers, all 9 still `proposed`.** Nobody has ever accepted a memory.

### 7.0 The reason, and it is not the UI — REAL, and the highest-value change here

The original blamed the proposer's empty action row. That explains why the *proposer* is stuck; it does not explain why the *partner* never accepted. Verified: no `memory` edge function exists, `_FeatureTile` (`closer_screen.dart:305-308`) carries `emoji, title, blurb, route` and has nowhere for a count, Memory Threads is the ninth of nine tiles, and behind it is a second PIN. **The partner has never accepted because the partner has never been told.**

Three pieces, none large:

1. **`supabase/functions/memory-notify`**, modelled on `reach-notify`, using the 004700 shared secret. Called by the client after a successful propose with `{memory_id}`; it resolves the couple, finds the partner, and sends a **contentless** push: *"She proposed a memory."* The content is encrypted; there is nothing to leak and nothing to render.
2. **A count dot on `_FeatureTile`**, fed by `head: true, count: exact` over `state='proposed' and proposer <> auth.uid()`. Both columns are plaintext, so no decryption and no PIN.
3. **Acceptance is one tap** — `memory_accept(id)` with null notes. §7.1 is offered afterwards.

Everything else in this section is downstream of this working.

### 7.1 Acceptance is authored — REAL, but a follow-up, not a gate

Proposing writes *your* account. After accepting, the partner is invited to write *theirs*, and the memory permanently carries both:

> **He wrote —** *We ate everything in the fridge by candlelight.*
> **She wrote —** *You were so pleased with yourself about the candles.*

Two columns, one optional RPC pair, one screen. It is the smallest change here and probably the highest value-per-line — it converts acceptance from a chore into the interesting half. But it is **not** the gate: making the one transition running at zero more expensive is the opposite of the fix, and `memory_accept`'s note parameters default to null precisely so the fast path exists.

### 7.2 On this day — REAL, but it needs the push to matter

Every accepted memory surfaces itself on its own day-of-year. Pure client arithmetic over `happened_on`; the partial index is there for when the count grows.

Honest caveat the original omitted: **with 9 memories the chance any given open matches is ~2.5 %; at 50 it is ~13 %.** He will ship this and never see it fire. Worse, the band lives *inside* the PIN gate, so it can never pull anyone back into the app — it rewards people already there. The version that works is the anniversary push, and since §7.0 already builds the notify function and `happened_on` is plaintext, it is a cron trigger on an existing function rather than new infrastructure. **Ship the band and the push in the same phase, or ship neither.**

### 7.3 A memory belongs to a place, and often to a visit — REAL, and the best idea here

`public.visits` exists with `start_date / end_date / location / note / is_upcoming` (6 rows live), couple-scoped RLS, a model, and `timeline_repository.dart:16-24`.

When `happened_on` falls inside a visit's range, the composer offers it pre-filled — *"During your Lisbon trip, 12–19 Mar 2024"* — and stores `visit_id`. The thread groups those:

```
 ◈ ── LISBON · 12–19 March 2024 · 7 days ─────────────
 │   ● The night the power went out
 │   ● The bakery on the corner
 ◈ ────────────────────────────────────────────────────
```

That is the shape of a long-distance relationship: months of distance punctuated by visits. It is the one idea here that would not apply to a co-located couple, and it costs one nullable FK. **It only fires if §4.4's EXIF default lands** — matching against a date the user typed by hand from memory in August will match nothing.

Free-text place goes in `place_cipher`, encrypted, even though `visits.location` is already plaintext: a new place name should not be born in cleartext because an old one was.

### 7.4 Revisit — cut it, and delete the dead API

Today "Revisit together" upserts a `memory_revisits` row that **nothing ever reads**: `fetchRevisit` (`repository.dart:341`) and `acknowledgeRevisit` (`:334`) both have zero call sites and the table is empty. It toasts *"Asked your partner to revisit."* and the partner is never told anything.

The synchronous version — "She's looking at *Lisbon* right now, [Join her]" — requires both partners simultaneously foregrounded, past an app lock, past a PIN, on the ninth tile, in a **long-distance** relationship with a timezone offset, with no mechanism to summon each other. The realistic hit rate is zero.

**Delete `requestRevisit` / `fetchRevisit` / `acknowledgeRevisit`, the chip, and the table.** If shared looking is wanted later, the honest version is asynchronous — *"she looked at Lisbon yesterday"* — and needs no realtime at all. Shipping a button whose only effect is a toast is worse than shipping nothing.

### 7.5 Speculative, labelled

- **The thread as an artifact** — a year-end "your thread, 2026" rendered on-device as one long encrypted image. Attractive, unbounded, no design.
- **Asynchronous "she looked at this"** — the salvageable half of 7.4. One column, one band. Not costed.
- **Per-photo removal consent** — asking before removing a photo *she* added. v1: you remove what you added; the memory as a whole is dual-consent. Extending consent to individual photos is a second state machine for a much smaller stake.
- **A memory proposed from a chat message** — long-press a chat photo → "make this a memory". Needs a bridge between an unencrypted chat object and an encrypted Closer one: download, decrypt, re-encrypt. Real but not small.

---

## 8. Migration of existing rows

**Step −1, blocking, before any DDL.** Verified: the ledger's newest entries are `20260814005550 key_escrow`, `20260814000942 memory_threads_and_rituals_delete_columns`, `20260814000618 vault_media_columns` — timestamp versions sharing no scheme with the repo's `20260601006xxx` filenames. Migrations here are applied through `apply_migration`, not `supabase db push`; the repo files are a mirror. Confirmed by the divergence: `couple_intimate.allowed_mime_types` already contains `application/octet-stream` (006400's effect is live) while `memory_threads.delete_requested_by` still points at `auth.users` (006300's effect is not). Before shipping: apply A and B by name through `apply_migration`, mirror the files, and reconcile or retire `20260601006300` so nobody ever runs `db push` against this project.

**The nine legacy rows cannot be backfilled server-side.** Only the couple's devices hold the key; the seed lives in `FlutterSecureStorage` and `exportPrivateSeed` is the only way out. `photo_cipher`/`photo_nonce` therefore stay in the schema permanently.

**`memory_heal.dart`**, shaped like `thumb_backfill.dart:25-101`:

1. Runs only when `CryptoCore.exportSharedKeyBytes() != null` — the §3.9 guard, non-negotiable. Verified: one production row has a 24-zero nonce and 16-zero packed MAC, the `_isLegacy` signature, which `decryptBytes` returns **without needing a key**. Without the guard, heal in plaintext mode succeeds on that row, re-uploads it as cleartext behind a signed URL, and nulls the original column — erasing the evidence of the very thing it was meant to fix.
2. One row at a time, dwell-gated (only while the timeline has been idle ≥ 2 s), never during a scroll.
3. Decrypt inline (`'${threadId}_photo'`), `Thumbnails.derive`, mint `photoId`, upload c/t/f, insert `memory_photos` at position 0, **then** `update memory_threads set photo_cipher = null, photo_nonce = null`. Upload-then-claim, exactly like `thumb_backfill`.
4. Any failure leaves the row untouched and retries on the next dwell. The inline column remains the source of truth until the child row exists.
5. The read path keeps the legacy branch forever: `cover_path == null && photo_cipher != null` → decrypt inline, decode bounded at `coverPx`.

**The one cleartext row** re-encrypts as a side effect of step 3. It is worth him knowing it exists right now: that photo is readable by anyone with database access today.

---

## 9. File-by-file plan

### New

| file | what |
|---|---|
| `supabase/migrations/20260601006800_memory_threads_redesign.sql` | §2.4 |
| `supabase/migrations/20260601006900_memory_consent_rpcs.sql` | §2.5 |
| `supabase/functions/memory-notify/index.ts` | §7.0, modelled on `reach-notify` |
| `mobile/lib/features/closer/memory_threads/memory_media_cache.dart` | §3.2–3.3, 3.6, 3.8. Owns providers, not bytes |
| `.../memory_decode_queue.dart` | §3.7 |
| `.../memory_photo_queue.dart` | §4, persisted |
| `.../memory_actions.dart` | §5.2, pure, no I/O |
| `.../memory_failure.dart` | §6.6, classification + exact copy |
| `.../memory_heal.dart` | §8 |
| `.../memory_timeline_screen.dart` | §6.2 |
| `.../memory_gallery_screen.dart` | §6.3 |
| `.../memory_composer_screen.dart` | §4.3 |
| `.../widgets/{memory_entry,memory_cover,thread_rail,year_scrubber,on_this_day_band,consent_band,upload_progress_row}.dart` | §6 |

### Modified

| file | change |
|---|---|
| `memory_thread_repository.dart:145-195` | named-column select incl. `cover_path`; delete `fetchThreads` (zero call sites); `.stream()` → realtime delta channel |
| `…:200-253` | `propose` no longer takes photo bytes; adds place/visit; fires `memory-notify` |
| `…:256-317` | every mutator becomes an `rpc()` with `bytesToBytea` arguments |
| `…:321-356` | **deleted** — revisit API and table |
| `…:379-404` | batched decrypt returning classified failures |
| `crypto_core.dart:85-89,103-130` | add `keyEpoch`, bump on both; bump is a clear |
| `crypto_core.dart` | add `decryptBytesOffThread(Uint8List packed, {String? associatedData})`, raw bytes, no base64 |
| `thumbnails.dart` | add `derive(Uint8List) → (cover, tile, capturedAt)`; add `kMemoryCoverMaxEdge` |
| `media_decode.dart` | add `kMemoryTileMaxEdge`; **wire `kZoomUpgradeScale`/`kZoomRevertScale` to a real layer** |
| `media_viewer.dart` | mount the zoom upgrade layer (fixes chat too) |
| `media_source.dart:78` | correct the stale "~720px" comment |
| `vault_media_cache.dart` | switch to `decryptBytesOffThread`; adopt epoch keying |
| `chat_send_queue.dart:79,213-242` | split net/CPU semaphores |
| `supabase_repository.dart` | TOFU pin `sha256(partnerPub)`; stop using `keyWasReplaced` as a failure signal |
| `memory_pin_gate.dart` | Forgot PIN; confirm-entry; 6 digits (same commit); delete `tryBiometricOrRequirePin` (zero call sites); keep device-credential fallback |
| `closer_screen.dart:305-308` | `_FeatureTile` gains an optional count dot |
| `core/app/router.dart:310-315` | new routes |
| `main.dart` (~:268) | `MemoryMediaCache.clear()` + `imageCache.clear()` + `clearLiveImages()` on cover raise |

### Deleted

`propose_memory_screen.dart` (305 lines); `memory_threads_screen.dart:298-1050` (the whole unlocked view — the PIN gate at `:52-296` survives, modified); `memory_revisits` and its three zero-call-site APIs; `clearAppPin`'s dead-code status (it becomes reachable).

---

## 10. Tests

### Widget/unit — `flutter test`, no device

1. **Decode identity.** Gallery tile provider and pager underlay provider are `==` for one photo; the cover provider is deliberately *not*, and the test asserts both. Asserts provider **equality**, not a constant's value — the previous bug (a stray `height:`) would have passed a constant test.
2. **Cache keys.** `coverKey != tileKey != fullKey`; two different signed URLs for one path give one key; the key is path-derived and epoch-prefixed.
3. **LRU instance identity.** Two `get()` calls for one path return the *identical* `Uint8List`. A copy silently doubles every decode.
4. **ImageCache eviction.** Evicting an L2 entry calls `imageCache.evict(provider, includeLive: true)`; `clear()` empties `imageCache` and live images. Assert with a fake `ImageCache`.
5. **Epoch bump clears.** After a bump, the old-epoch entries are unreachable **and** the map is empty.
6. **Memo invalidation.** A realtime UPDATE carrying a new `partner_note_cipher` for a memoized thread yields the new plaintext without a restart.
7. **Action matrix.** Table-driven over 5 states × {proposer, partner} × {<14 d, ≥14 d} against `actionsFor`. The vault's equivalent matrix has no test at all.
8. **Expiry uses the server clock.** `ServerClock.setOffsetForTest(-Duration(days: 30))` — a device 30 days fast must **not** offer force-delete.
9. **AD strings frozen.** Golden assertion on the literal six new strings, including `memoryId` in the photo ADs. The cheapest insurance against the one change that destroys all data irreversibly.
10. **Refuse-cleartext.** With `_sharedKey == null`, the upload path throws; a packed blob whose first 40 bytes are zero throws. Both, separately, in the heal path too.
11. **Legacy inline round-trip.** A zero-nonce/zero-MAC `photo_cipher` still opens.
12. **Photo/nonce pair.** Constructing a thread with `photoCipher` set and `photoNonce` null throws rather than producing the blank-black-screen state.
13. **Failure copy.** `SecretBoxAuthenticationError` → permanent; `StateError` → temporary; 403-after-refresh → transient; 404 → missing; TOFU mismatch → its own string; **and no produced string contains the exception's `toString()`**.
14. **bytea RPC encoding.** Every `rpc()` bytea argument is a `\x`-prefixed hex string, never a `List<int>`. Asserts against a recording Postgrest fake.
15. **Empty ≠ unreadable.** `items: []` with `unreadable: 3` renders `unreadableMessage`, not the first-run empty state.
16. **Queue ordering and split semaphore.** 12 picks → positions 0..11 in pick order; ≤3 network in flight; **≤1 CPU in flight**; one failure leaves 11 alive and the failed one retryable.
17. **Queue survives a restart.** Enqueue 12, kill the isolate holding the queue, rehydrate: the 9 unfinished items are present with their positions, and the timeline entry reports "3 of 12".
18. **Decode queue drops stale work.** Enqueue 45 jobs, move the visible range, assert the off-screen jobs never run.
19. **EXIF default.** A JPEG with a known `DateTimeOriginal` yields that date; one without falls back to mtime; the earliest of a batch wins.
20. **Column hygiene.** Extend `test/unit/hygiene/repo_hygiene_test.dart` to diff every column the memory repository writes against a checked-in schema snapshot **and** against Migration B's grant list — a write to an ungranted column is a test failure, not a runtime 403. This is literally the test 006600's own header asks for after *"Third instance of the same fault in one session"*.
21. **Migration hygiene, corrected.** The original's "sorts after 20260601006700" is worthless here — verified, the ledger and the filenames share no scheme. Replace with: no `references auth.users` without an `on delete`; no `references profiles/couples` with NO ACTION; no CASCADE onto a jointly-owned table; and the repo file's `apply_migration` name is recorded alongside it.

### Device-only — IN2015 / Vivo / OnePlus7, not assertable in CI

- Time-to-first-cover on a cold open of 50 memories, and whether any indicator appears.
- Whether a spinner ever appears while flinging at 60/90 Hz — needs a real raster thread.
- Real AOT-release cost of an inline 120 KB decrypt vs. an isolate hop, which is the empirical basis for §3.6's threshold. Every timing figure in the original research was measured on Windows x64 under the JIT VM and is an **optimistic lower bound**.
- Peak RSS with L2 full — covers ≤ 30 MB, tiles ≤ 46 MB decoded, and the ImageCache not exceeding its budget with a gallery open.
- Two-device realtime: an accept on A landing on B, and whether the now-tiny payload fixes any oversized-payload drops. It remains unestablished whether Supabase Realtime silently drops rows carrying a 1.58 MB `photo_cipher` — if it does, realtime for photo-bearing memories may never have worked.
- `FLAG_SECURE` actually applied on the composer and PIN gate. `SecureScreen` swallows `MissingPluginException` (`secure_screen.dart:30-38`), so it is a silent no-op if `MainActivity` is not wired.
- HEIC from a real gallery through `pickMedia`, and whether EXIF survives that provider.
- **After an OS process kill from backgrounding, `getTemporaryDirectory()` contains no plaintext.** This is the claim the entire L1-is-ciphertext design rests on and it cannot be asserted in a unit test.
- `delete_my_account` against a seeded delete-state row **and** a seeded accepted memory the deleted account proposed, confirming both FK fixes.
- Whether `createSignedUrls` accepts 24–48 paths in one request without a server-side cap. `MediaUrls.warm` has no batching and no in-flight dedupe (verified), so two overlapping `warm()` calls for the same paths issue two requests, and a cap would silently degrade the prefetch to a partial warm with per-tile `sign()` calls during scroll.
- The push actually arriving on a disguised, battery-optimised handset.

---

## 11. Out of scope

**Video in memories.** Playing encrypted video needs a decrypted *file* on disk, which is precisely the plaintext-at-rest exposure §2.1 exists to eliminate. No streaming-decrypt path exists in this codebase. Videos are filtered out of the pick with a named reason rather than failing at upload.

**Server-side backfill of the nine inline photos.** Impossible in principle; heal-on-read is the only mechanism, and the columns stay permanently.

**A service-role edge function to drain `storage_reap` through the Storage API.** The table and trigger ship now; the SQL reaper unlinks `storage.objects` rows exactly as `20260601003400` already does, which does not itself delete the backing blob. Named, not pretended away.

**Strengthening `KeyEscrow`.** The wrapping key is a single HKDF-SHA256 over the raw password with no iteration count (`key_escrow.dart:37-42`) — an offline brute-force target at roughly one HMAC per guess, against ciphertext and salt the server holds. A real defect. It belongs to crypto-core, changes the escrow wire format for every Closer feature at once, and cannot be scoped inside this redesign. `backup()` also swallows every error (`:98-102`), so a user can be told they are protected when no row landed.

**Replacing the PIN hash.** `memory_pin_gate.dart:90-97` is unsalted 32-bit FNV-1a over a 10,000-value space — enumerable in microseconds if the secure-storage entry is read. Widening to 6 digits is in scope; replacing the hash with a real KDF should happen across every PIN in the app at once.

**The same DELETE hole on the vault.** 001400's `do $$` loop created identical `*_delete_member` policies for `vault_items`, `afterglow_entries`, and `couple_dissolutions`, so the vault's "dual consent" has exactly the hole §2.5 closes here. One-line fix each; flagged, not bundled.

**Out-of-band key verification UI.** §3.9's TOFU pin detects a change; a safety-number screen for two people to compare is a separate design.

**iOS.** `FLAG_SECURE` has no equivalent (`secure_screen.dart:11`) and the disguise machinery is Android-shaped.

**Cross-couple sharing, export, or any read path leaving the two devices.**

**A plaintext blurhash or thumbnail hint for instant cold paint.** Rejected deliberately: it is a low-resolution copy of an intimate photo stored where anyone with database access can read it, in a feature whose entire promise is that the server cannot see the picture. The prefetch is the answer instead, and it is weaker on a genuinely cold device — the correct trade, stated out loud rather than quietly buying smoothness with the thing the feature protects.

---

## 12. Build sequence

| # | step | why here |
|---|---|---|
| **−1** | **Reconcile the migration ledger.** Confirm A and B apply by name via `apply_migration`; retire the `db push` path. | Verified divergence: 006400's effect is live, 006300's is not. Ten minutes, and it is the difference between a clean apply and a surprise. |
| **0** | **Migration A.** Schema, both FK regressions, widened guard, CHECK constraints, dedup index, cover trigger, reap table, purge cron, realtime publication. | Zero client change. Closes two **live** account-deletion faults: `delete_requested_by`/`deleted_by` NO ACTION against `auth.users`, and `proposer` CASCADE destroying the surviving partner's half. Both verified this session. |
| **1** | **Migration B + the vault's twin.** Revoke DELETE and table-level UPDATE, drop the delete policy, column grants, the RPCs. | Verified live: `authenticated` holds `DELETE,UPDATE,SELECT,INSERT` and `memory_threads_delete_member` permits a hard delete of any row in the couple. "Dual consent" is currently a client `if`. No UI work depends on this. |
| **2** | **`memory-notify` + the tile dot + one-tap accept.** | The reason nine of nine are stuck. One edge function modelled on `reach-notify`, one optional field on `_FeatureTile`, null note arguments. Everything downstream assumes acceptance happens. |
| **3** | **Read path.** Named-column select, realtime delta, batched memoized title decrypt. | ~40 lines. 14.1 MB → 40 KB on the list before a pixel of UI work. Ships and is felt on its own. |
| **4** | **Honest failures + PIN recovery.** Classification, `unreadableMessage` wired, every `$e` deleted, TOFU pin, Forgot PIN, confirm-entry, 6 digits, `SecureScreen` on composer and gate. | Mostly text. Removes the ugliest thing that can appear on this screen and unbricks the device of anyone who forgot four digits — which today compounds with key loss into total data loss. |
| **5** | **`MemoryMediaCache` + `MemoryDecodeQueue` + `memory_photos` + heal-on-read.** Own `CacheManager`, ImageCache eviction discipline, inline-vs-isolate threshold, raw-bytes `decryptBytesOffThread`, 403 owner. | The load-bearing infrastructure. Everything after consumes it. This is the commitment point. |
| **6** | **Persisted `MemoryPhotoQueue` + multi-select composer + EXIF date.** | Requirement #6. The persistence is not optional — without it multi-select makes the existing silent-loss failure twelve times bigger. The EXIF default is what makes step 9 fire. |
| **7** | **Gallery pager + zoom upgrade layer.** | Requirement #5. Trivial now; the layer also fixes chat, where pinching to 5× currently magnifies a viewport-width bitmap. |
| **8** | **Timeline redesign + rail + search + year scrubber + on-this-day band + anniversary push.** | Requirements #1 and #2. Most design time, deliberately last among the required items because it is the only one that benefits from the others already working. Search is not optional at fifty memories. |
| **9** | **Visit linking.** | One FK; `visits` and `TimelineRepository` already exist; §4.4 already supplies the date. |
| **10** | **Authored acceptance (§7.1).** | Two columns, one RPC already written, ~40 lines of UI. Highest value-per-line in the document — after acceptance is actually happening. |

Steps −1 through 4 are independently shippable and each improves the current screen without touching its layout.

---

## The single most likely reason it still feels slow on his phone

Everything above removes bytes and decodes. What it does not remove is a **serial chain of network round trips before the first cover byte can move**: session refresh → the metadata query → `createSignedUrls` → the object fetch. Only the last of those is parallel across covers; the first three are strictly ordered, each one a full RTT to the Supabase region, and `MediaUrls.warm` will not even be *called* until the metadata query has returned. On a mobile link from his handset that is realistically 600–900 ms of pure latency on a cold open, during which the CPU is idle and the network is idle between hops.

So after this work the feature is **latency-bound, not bandwidth- or CPU-bound**, and the one remaining lever is collapsing that chain — a single RPC that returns the metadata *and* the signed URLs in one response, and firing it on gate mount rather than after it. Until that exists, a cold open will feel like about a second of a beautifully laid-out timeline with no pictures in it, and no amount of cache tuning will change that number.