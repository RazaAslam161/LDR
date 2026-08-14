# Shared Vault — Final Implementable Specification

**Status of evidence.** Every claim below was checked this session against `sopictusdonlvuezmfep` (11 rows, live) and the working tree at `E:\LDR`. Nothing was run on a device. Wall-clock, frame traces and RSS remain unmeasured — see §8.

---

## 0. Rulings

### 0.1 Corrections to the design, all confirmed

| # | ruling | evidence |
|---|---|---|
| **R1** | **The named-column select must not drop `ciphertext`.** `VaultItem.fromJson` opens with `byteaToBytes(json['ciphertext'])` and `byteaToBytes(null)` throws `ArgumentError` (`closer_crypto.dart:106-108`), caught at `private_vault_repository.dart:194` → `unreadable++`. All 11 rows drop; `private_vault_screen.dart:331` then renders `_EmptyVault`. Step 1 as designed shows an empty vault over 11 intact rows. Critiques 1 and 3, both correct. | verified in source |
| **R2** | **The publication column list breaks build 14 on both handsets.** `SupabaseStreamBuilder` replaces a cached row wholesale with `payload.newRecord` (`supabase-2.13.0/lib/src/supabase_stream_builder.dart:203`, INSERT at `:193`). Under a column list `newRecord` has no `ciphertext` → `ArgumentError` → the row silently vanishes. Sideloaded, no update channel. Critique 3, correct and decisive. | verified in package source |
| **R3** | **`reap_storage_objects()` cannot run.** Live trigger `protect_objects_delete BEFORE DELETE ON storage.objects FOR EACH STATEMENT EXECUTE FUNCTION storage.protect_delete()` raises `42501` on any direct delete. Worse, §8 of the design moved the *working* client-side `storage.remove()` out, so the net effect would be that hard-deleting an intimate photo stops removing the file. Critique 3, correct. | verified live in `pg_trigger` |
| **R4** | **The disguise does not leak plaintext by the mechanism claimed.** `main.dart:586-600` returns a *different* `MaterialApp` (`DisguiseCoverHost`) when `!isReal`; the router subtree is unmounted and `PrivateVaultScreen.dispose()` **does** run. Critique 2, correct — see §0.2 for the part it overstates. | verified in source |
| **R5** | **`deriveSharedKey` is not idempotent** — no early return, recomputes ECDH+HKDF and reassigns on every call (`crypto_core.dart:103-130`). `closer_crypto.dart:14-15`'s "Idempotent: caches the result" is false, and 12 call sites rely on it. A `keyEpoch` bumped per call thrashes the whole cache on every Closer navigation. Critique 2, correct. | verified in source |
| **R6** | **The plaintext downgrade is still open.** `deriveSharedKey` sets `_sharedKey = null` and returns **normally** on non-base64 (`:110-114`) and length ≠ 32 (`:115-118`); `ensureSharedKey` guards only the `legacyPublicKey` literal (`closer_crypto.dart:44-49`); `encryptBytes` with a null key emits zero-nonce/zero-MAC cleartext (`crypto_core.dart:176-186`). Critique 2, correct. | verified in source |
| **R7** | **`ad` is `base64UrlEncode` — its alphabet contains `_`** (`private_vault_repository.dart:372-379`). `'${id}_${ad}_tile'` is unambiguous only by accident. Critique 2, correct. | verified in source |
| **R8** | **`reconfirm_due` has no expiry mechanism.** Grep across `lib/` and `supabase/`: written at `:288`, parsed at `:158`, indexed by `vault_ephemeral_idx`. No cron, no edge function, no client check. The ephemeral L1 ban buys nothing and costs half the vault (live: 4/8 photos + 1/2 notes are ephemeral). Critique 3, correct. | verified live + grep |
| **R9** | **Two decode widths for one item across grid and pager is two decodes.** `MediaItem.tileDecodeWidth` (`media_source.dart:80`) already solves this and is consumed at `partner_profile_screen.dart:404`. The design's per-surface table drops it. Critique 1, correct. | verified in source |
| **R10** | **The video row has a 16-byte inline blob.** `f9853e45` `ct_len = 16` → `fromJson`'s `blob.length < 16` guard passes and `cipherBytes` is **empty**. No branch in the read path handles it. Critique 3, correct. | verified live |
| **R11** | **`FLAG_SECURE` is wired and needs ref counting.** `MainActivity.kt:52-72` registers `miles/secure_screen`; the native side is one `secureFlagSet` boolean. Drop the "might be a silent no-op" caveat; add the ref count. Critiques 2 and 3, correct. | verified in source |
| **R12** | **`getSingleFile` requires a URL, and `flutter_cache_manager` persists the fetch URL in its sqlite index.** Keying L1 by path is necessary but not sufficient — signed capability URLs for intimate media would sit in a plaintext on-disk DB. Critiques 1 and 2, correct. | verified in package source |

### 0.2 Where a critique is wrong — one line each, original kept

- **Critique 2, §0.1:** right that the mechanism is wrong (the route *is* unmounted), but its own item (a)(2) concedes `unawaited(clear())` may not drain during the pause transition — so "the leak does not exist" is unproven, not false; the fix is identical either way, and §5 keeps the wipe.
- **Critique 1, #2:** `c6dce7e3` is a 323 KB JPEG, roughly 2–3 MP, not "a 12 MP decode on tap" — the double-decode defect stands, the magnitude does not.
- **Critique 1, #4:** the 96-entry L2 is inherited from the Memory spec's 50-row timeline; it was never justified for a 3-wide vault grid, so the fix is right but the framing ("overruns the budget the moment anyone zooms") is a symptom of a number that was wrong from the start, not of the zoom layer.
- **Critique 2, "VaultCipherCache … 24 signed capability URLs sitting in a plaintext on-disk database":** true, but the severity is bounded — `_ttl` is 24 h (`media_urls.dart:39`) and the DB is inside the app's private data dir, which `allowBackup="false"` already closes. Fix it anyway (§3.1); do not rank it above the orphan class.

---

## 1. What the user sees

### 1.1 Cold — first ever open on this install, nothing on disk

1. The grid **lays out immediately**: 100 fixed `MilesColors.surface1` squares, 3 across, correctly sized, no spinner. There is no `CircularProgressIndicator` anywhere on this screen after this work — `private_vault_screen.dart:316`, `:327-328`, `:507-513` are all deleted; the write-path banner at `:621` stays.
2. Key derivation runs **in parallel** with the metadata query, not before it. Today `_ensureKeyAndInitStream` (`:42-60`) awaits two network round trips (`publishMyPublicKey` + `fetchPartnerPublicKey`) behind a full-screen spinner before the grid exists. Layout does not need the key.
3. The first 24 tiles arrive over roughly a second on a slow link — one `createSignedUrls` call, then 24 × ~20 KB fetched at network concurrency 6.
4. Notes render their text. Voice renders a `surface2` tile with a duration chip and decrypts nothing. Video renders its poster.
5. Nothing that fails renders `$e`. A failed item stays in the grid with a muted panel and one sentence (§3.6).

**Honest number:** the chain *session refresh → metadata query → `createSignedUrls` → object fetch* is strictly serial. Realistically 600–900 ms of pure latency before the first tile byte moves. See the closing section.

### 1.2 Warm — second visit, same process

L2 is still populated, L3 still holds the decoded frames. Tap the feature tile and the grid is **already painted**. Tap a photo and the pager's first pixel is a composite of the identical `MemoryImage` instance already resident in `ImageCache` — no I/O, no decode.

### 1.3 Warm — second visit, fresh process

L1 (ciphertext, own store, 90 days) survives. The screen checks `getFileFromCache(path)` **before** signing anything, so a fully-cached vault paints from disk with **zero** network calls. This is the fix for the design's "second visit costs nothing", which as written still paid two round trips (R12).

Ephemeral items are cached too, with `maxAge` clamped to `reconfirm_due - now` (§5.4) — the ban is lifted because the mechanism it defended against does not exist (R8), and is replaced by one that does.

### 1.4 What is visibly better, in the order he will notice it

Tiles are sharp (400 px against a 353-physical-px cell; today's 300 px is a 1.18× upscale — `private_vault_repository.dart:239-244`). Scrolling does not stall. Tapping is instant-but-soft, then sharp — **not** "instant": the underlay is a 400 px tile stretched `BoxFit.contain` into a 1080 px viewport, and that is the honest claim. Three photos that cannot be opened at all today can be opened. Nothing shows an exception string.

---

## 2. Data model + SQL

### 2.1 The rule, corrected

**The picture leaves the row — but the row keeps a 16-byte stub, permanently.** `ciphertext` is `bytea not null` and cannot be nulled per row without a schema change. Two mechanisms, not one:

- **Split the read.** The grid's query carries no ciphertext. A second, bounded query pulls inline bytes only for the rows that still need them.
- **Shrink what remains.** After both derived objects for a row are confirmed present and MAC-verifying, heal overwrites `ciphertext` with its own first 16 bytes. That shape already exists in production (`f9853e45`, `ct_len = 16`), so the read path must handle it anyway (R10).

Together: 1,675,329 B → ~30 KB metadata + ~766 KB bounded inline today, → ~30 KB + ~100 B once heal completes.

### 2.2 Storage layout

```
$coupleId/vault/$ad.enc          original   — EXISTING, unchanged, 6 objects ↔ 6 rows verified
$coupleId/vault/t/$itemId.enc    tile       — NEW: 400 px longest edge, JPEG q72, ~20 KB
```

Couple id stays segment 1 — every live policy tests `(storage.foldername(name))[1] = current_user_couple_id()::text`. No new storage policy.

Uploaded `application/octet-stream`, `cacheControl: '31536000'`, packed `nonce||mac||ct` via `packFull`.

**`upsert: true` is forbidden** — verified live, `couple_intimate` has `intimate_select` (r), `intimate_insert` (a), `intimate_delete` (d) and **no UPDATE policy**. A retry over an existing path removes first:

```dart
try {
  await storage.uploadBinary(path, packed, fileOptions: _octet, retryAttempts: 2);
} on supabase.StorageException catch (e) {
  if (e.statusCode != '409') rethrow;
  await storage.remove([path]);          // no UPDATE policy — replace, never upsert
  await storage.uploadBinary(path, packed, fileOptions: _octet, retryAttempts: 2);
}
```

Two tiers, not three. No 1024 px cover — the vault's only grid is `crossAxisCount: 3` with 2 px spacing (`private_vault_screen.dart:334-342`); on an IN2015 a cell is 134.5 dp = 353 physical px, and no surface in this feature is full-bleed. No `aspect` column (fixed squares cannot reflow). **No blurhash** — see §9.

### 2.3 Associated data — the frozen wire contract, per slot

`ad` is `base64UrlEncode` of 24 random bytes and its alphabet contains `_` (R7). The separator is `|`, which appears in neither base64url nor a UUID.

| slot | scheme 1 (all 11 existing rows) | scheme 2 (new writes) |
|---|---|---|
| inline preview | `'$ad'` | **`'$ad'` — unchanged** |
| note / trace body | `'$ad'` | **`'$ad'` — unchanged** |
| original `.enc` | `'$ad'` | `'v2\|$id\|$ad\|full'` |
| tile `.enc` | **`'v2\|$id\|$ad\|tile'`** | **`'v2\|$id\|$ad\|tile'`** |

**Tiles are containment-bound unconditionally, at both schemes** — a tile only ever exists on a row that has one, so there is nothing to break. `ad_scheme` discriminates **the original only**. State it exactly once, in the column comment; the design stated it two contradictory ways (Critique 3, #4).

**`ad_scheme` is a hint, not an authority.** It is a plain `smallint`; flipping 1→2 on a legacy row is a MAC failure that §3.6 would otherwise classify as permanent, alarming, and sticky. So: **on a MAC failure decrypting an original, retry once with the other scheme's AD before classifying.** This does not weaken containment — a swapped object was sealed under a different item's `id`, so neither candidate verifies. It also removes the "changing a value destroys the row" footgun.

**Do not grant `ad_scheme` to `authenticated`.** It is write-once at insert; heal never legitimately changes it.

**`itemId` is client-minted.** `vault_items.id` defaults to `gen_random_uuid()` and the insert at `:279-293` does not supply it. Mint a `Random.secure` v4 UUID before encrypting. Nonce reuse is a non-issue — `_aead.encrypt` mints a fresh 24-byte nonce per call.

**Residual, stated not hidden:** existing originals stay swappable between two rows of one couple by an adversary with DB write access. Fixing it requires re-encrypting every original from a device that holds the key. Tiles are bound from day one.

### 2.4 Migration V-A — `vault_tiles_and_wire` (safe against build 14)

```sql
-- ── Columns ──────────────────────────────────────────────────────────────────
alter table public.vault_items
  add column if not exists tile_path  text,
  add column if not exists ad_scheme  smallint not null default 1;

comment on column public.vault_items.tile_path is
  'Object name in couple_intimate holding the encrypted 400px tile, '
  '$coupleId/vault/t/$id.enc. Null OR a 404 on fetch means fall back to the '
  'inline ciphertext preview, fetched by the bounded second query.';
comment on column public.vault_items.ad_scheme is
  'Associated data for the ORIGINAL object only. 1 = the bare ad token (every '
  'row written before build 15). 2 = containment-bound, v2|id|ad|full. '
  'TILES ARE ALWAYS v2|id|ad|tile AT BOTH SCHEMES. The inline preview and the '
  'note body are ALWAYS the bare ad token at both schemes. This column is a '
  'HINT: on a MAC failure the client retries the other scheme before '
  'classifying the row as unreadable.';

alter table public.vault_items
  add constraint vault_items_ad_scheme_ck check (ad_scheme in (1, 2));

-- ── Index that supports the actual query ─────────────────────────────────────
-- Today only vault_couple_idx(couple_id) exists, and `deleted` is filtered in
-- Dart (private_vault_repository.dart:190) so deleted rows are paid for on the
-- wire first.
create index if not exists vault_items_couple_created_idx
  on public.vault_items (couple_id, created_at desc)
  where deleted = false;

-- ── Halve the realtime payload WITHOUT a column list ─────────────────────────
-- relreplident is 'f' (verified live). FULL ships old_record AND new_record,
-- i.e. the inline ciphertext twice: for c6dce7e3 that is ~646 KB of hex each
-- way, ~1.29 MB against Realtime's 1 MB max_record_bytes — over the limit, so
-- delete-consent on that row has near-certainly never propagated.
-- DEFAULT is SAFE for the installed build 14: SupabaseStreamBuilder reads
-- newRecord for INSERT/UPDATE and only needs the PK from oldRecord to locate a
-- DELETE. The publication COLUMN LIST is what breaks build 14 (R2) and is
-- deferred to V-C.
alter table public.vault_items replica identity default;

-- ── Ephemeral expiry: the mechanism §5.4 depends on ──────────────────────────
-- reconfirm_due has no consumer anywhere in the repo today (R8). Without this,
-- banning ephemeral items from the disk cache protects against nothing.
create or replace function public.vault_expire_ephemeral() returns integer
  language sql security definer set search_path = public as $$
  with x as (
    update public.vault_items
       set deleted = true, deleted_at = now()
     where retention = 'ephemeral' and not deleted
       and reconfirm_due is not null and reconfirm_due < now()
    returning 1)
  select count(*)::int from x $$;
revoke all on function public.vault_expire_ephemeral() from anon, authenticated;
select cron.schedule('vault-expire-ephemeral', '23 4 * * *',
                     $$select public.vault_expire_ephemeral()$$);

-- ── Storage reap: a LEDGER, not a deleter ────────────────────────────────────
-- `delete from storage.objects` is IMPOSSIBLE here. Verified live:
--   protect_objects_delete BEFORE DELETE ON storage.objects FOR EACH STATEMENT
--   EXECUTE FUNCTION storage.protect_delete()   -- raises 42501
-- and the trigger is right to: unlinking the row makes the blob unreachable via
-- the Storage API forever. The client's storage.remove() through the API
-- (private_vault_repository.dart:349-351, permitted by intimate_delete) STAYS
-- and remains the primary deleter. This table records what the client could not
-- reach, for a service-role edge function to drain later (§9).
create table if not exists public.storage_reap (
  id         bigserial primary key,
  bucket_id  text not null,
  name       text not null,
  queued_at  timestamptz not null default now(),
  drained_at timestamptz
);
alter table public.storage_reap enable row level security;  -- no policies
revoke all on public.storage_reap from anon, authenticated;

create or replace function public._vault_queue_reap() returns trigger
  language plpgsql security definer set search_path = public as $$
begin
  if new.deleted and not old.deleted then
    if new.storage_path is not null then
      insert into public.storage_reap (bucket_id, name)
        values ('couple_intimate', new.storage_path);
    end if;
    if new.tile_path is not null then
      insert into public.storage_reap (bucket_id, name)
        values ('couple_intimate', new.tile_path);
    end if;
  end if;
  return new;
end $$;

drop trigger if exists vault_queue_reap on public.vault_items;
create trigger vault_queue_reap after update on public.vault_items
  for each row execute function public._vault_queue_reap();

-- ── Pointless grant ──────────────────────────────────────────────────────────
revoke select on public.vault_items from anon;   -- RLS already blocks it
```

**The same `delete from storage.objects` bug exists in `docs/guides/memory-threads-spec.md` §2.4's reaper and in `20260601003400`. Fix both in this commit** — see §7 shared list.

### 2.5 Migration V-B — `vault_consent_rpcs`

Verified live: `authenticated` holds `SELECT, INSERT, UPDATE, DELETE` on `vault_items`, and `vault_items_delete_member` (polcmd `d`) permits a hard delete of any row in the couple. Dual consent is a client `if`, and the 14-day window is computed from the handset clock (`private_vault_repository.dart:139-143`).

**V-B ships after the client that calls the RPCs.** Applied first, build 14's `requestDelete` / `cancelDeleteRequest` / `hardDelete` (plain PostgREST updates at `:312, :321, :341`) 403 permanently on a phone with no update channel (Critique 3, #2).

```sql
drop policy if exists vault_items_delete_member on public.vault_items;
revoke delete, update on public.vault_items from authenticated;

-- vault_items_update_member (polcmd 'w') SURVIVES — verified live — so the
-- column-level grant below is what the heal path actually rides on.
-- ad_scheme is deliberately NOT granted: write-once at insert.
grant update (storage_path, tile_path, media_mime_type, ciphertext)
  on public.vault_items to authenticated;

create or replace function public.vault_request_delete(p_item uuid)
  returns void language plpgsql security definer set search_path = public as $$
begin
  update public.vault_items
     set delete_requested = true,
         delete_requested_by = auth.uid(),
         delete_requested_at = now()          -- server clock, not the handset's
   where id = p_item
     and couple_id = (select public.current_user_couple_id())
     and not deleted and not delete_requested;
  if not found then raise exception 'vault_request_delete: not permitted'; end if;
end $$;

-- vault_cancel_delete(p_item) same shape.
-- vault_hard_delete(p_item) additionally asserts
--     (delete_requested_by <> auth.uid())                      -- partner confirms
--  or (delete_requested_at < now() - interval '14 days')       -- requester timeout
-- and sets deleted/deleted_by/deleted_at, firing vault_queue_reap.
```

**The select must also return the server's verdict, or the button lies.** `fromJson:139-143` computes `deleteState` from `DateTime.now()` on the handset, so a device 30 days fast shows force-delete and then throws. Add to the metadata projection a generated expression the client reads instead:

```sql
-- exposed through the select list, not a column:
--   extract(epoch from (now() - delete_requested_at))::bigint as delete_age_s
```
`VaultItem.deleteState` is derived from `delete_age_s` when present, from the handset clock only as a fallback for a metadata-only row that predates it.

### 2.6 Migration V-C — `vault_publication_columns` (last, after both phones are on build 15)

```sql
alter publication supabase_realtime drop table public.vault_items;
alter publication supabase_realtime add table public.vault_items
  (id, couple_id, kind, nonce, ad, ad_scheme, created_by, created_at,
   retention, reconfirm_due, delete_requested, delete_requested_by,
   delete_requested_at, deleted, deleted_by, deleted_at,
   storage_path, tile_path, media_mime_type);
```

The drop/add momentarily de-registers the table; a subscription live at that instant stops receiving until resubscribe. Fine at two users, worth knowing.

### 2.7 Model changes

```dart
final Uint8List? ciphertext;   // was non-null
final Uint8List? mac;          // was non-null
bool get hasInline => ciphertext != null && ciphertext!.isNotEmpty;

/// R9: ONE decode width per item, across grid, pager underlay and precache.
/// Copied from MediaItem.tileDecodeWidth (media_source.dart:80).
int? get tileDecodeWidth => tilePath != null ? null : kTileDecodePx;
```

`fromJson` distinguishes **absent** from **null**: PostgREST omits unselected columns entirely, so `json.containsKey('ciphertext')` gates the parse. A genuinely-null value on a `not null` column is a schema violation and still throws. This is the single change that makes R1's projection possible at all.

`payload` stops base64-encoding on every access (`:114-118`); it exposes raw packed bytes and the base64 hop happens once at the boundary that needs it.

---

## 3. The paint path — exact constants

### 3.1 Three layers, explicit keys

```
L3  Flutter ImageCache        (provider identity, resize width) — 1000 entries / 100 MiB, NOT device-scaled
L2  plaintext LRU in RAM      key '${CryptoCore.keyEpoch}|$path'
      tiles   48 entries      (~20 KB plaintext, ~480 KB decoded each → ~23 MB L3 ceiling)
      fulls    2 entries      (only if ≤ 8 MB; a 100 MB pick is never retained)
L1  ciphertext on disk        key '$path'   (bucket-relative, never the signed URL)
      CacheManager(Config('milesVaultCipher',
        maxNrOfCacheObjects: 1500, stalePeriod: Duration(days: 90)))
```

**48, not 96.** A 3-wide grid's visible ±6 rows is ~30 cells; 96 buys nothing and, with the pager's three bounded frames (~19 MB) plus the zoom layer's unbounded decode, pushes past the 100 MiB `ImageCache` budget so that a pinch-and-back repaints thirty cells. On zoom revert the unbounded provider is **explicitly evicted**, not left to LRU.

**L1 is its own store** — `DefaultCacheManager` is 200 objects / 30 days (`flutter_cache_manager-3.4.1/lib/src/config/_config_io.dart:14-15`) and is the singleton every `CachedNetworkImage` in the app uses. `VaultCipherCache` is a **true static singleton** — `CacheManager` is documented as single-instance per key and `Config` builds a sqlite DB named for it; never construct one per screen.

**L1 never sees a signed URL, in the index or in the request key** (R12):

```dart
final hit = await _cm.getFileFromCache(path);        // disk FIRST — no sign, no RTT
if (hit != null && !hit.validTill.isBefore(now)) return hit.file.readAsBytes();
final url = MediaUrls.cached(bucket, path) ?? await MediaUrls.sign(bucket, path);
var res = await _http.get(Uri.parse(url));
if (res.statusCode == 401 || res.statusCode == 403) {
  final fresh = await MediaUrls.refresh(bucket, path);   // ONE retry — 403 has an owner
  if (fresh != null) res = await _http.get(Uri.parse(fresh));
}
await _cm.putFile(path, res.bodyBytes, key: path, maxAge: _maxAgeFor(item));
```

`putFile`'s first positional becomes the bucket-relative path, so the sqlite `url` column holds a path, not a capability token.

**L2 returns the identical `Uint8List` instance, never a copy.** `MemoryImage.==` compares `bytes` by reference; a copy silently doubles every decode and defeats L3. Test §8.3.

**L2 owns and hands out `ImageProvider`s, and tracks every one it handed out** (R-C1#3). `MemoryImage.obtainKey` returns `this`, and `ImageCache.evict` takes a **key** — evicting the inner `MemoryImage` leaves a `ResizeImage`-wrapped entry resident, which holds the inner provider, which holds the plaintext. So the L2 entry is:

```dart
class _L2Entry { final Uint8List bytes; final Map<int?, ImageProvider> providers; }
```

and eviction walks `providers.values`, calling `imageCache.evict(p, includeLive: true)` on each. Given R9 there is at most one bounded width per item, so the map is one or two entries. Nothing outside `VaultMediaCache` constructs a provider over vault bytes.

**`CryptoCore.keyEpoch` is derived from the key material, not from the call** (R5):

```dart
/// Stable across processes and identical on both devices for the same key.
/// A COUNTER cannot work: deriveSharedKey is not idempotent, so a counter
/// bumps twice on Closer hub → Vault for a key that did not change, wiping L2,
/// the whole ImageCache and a playing video's scratch file for nothing. It also
/// resets to 0 every launch, which makes §6's persisted unreadable markers
/// unmatchable across sessions and colliding within them.
static String keyEpoch = 'nokey';   // else hex of sha256(sharedKeyBytes)[0..8]
```

Recomputed at the end of `deriveSharedKey` and `adoptPrivateSeed`. **An epoch change is a clear, not a re-key** — a changed key leaves old plaintext reachable in the LRU forever. An *unchanged* epoch is a no-op, which is what makes §1.2 true.

### 3.2 Decode widths — one width per item, `height` never passed

| surface | provider | width |
|---|---|---|
| grid tile | `MemoryImage(tileBytes)` or `MemoryImage(inlineBytes)` | **`item.tileDecodeWidth`** |
| pager underlay | **same instance** | **`item.tileDecodeWidth`** |
| grid/pager precache | same instance | **`item.tileDecodeWidth`** |
| pager full | `ResizeImage(MemoryImage(fullBytes), width: viewportPx)` | `(MediaQuery.sizeOf(ctx).width * dpr).round()` |
| pager neighbour precache | same provider | **identical `viewportPx`** |
| zoom layer | `MemoryImage(fullBytes)` | **unbounded**, mounted above 1.5× |

`tileDecodeWidth` is `null` (unbounded) once a tile object exists — the 400 px object is its own bound. It is `kTileDecodePx` (512) while the row falls back to inline, which is the state **every production row is in today** and therefore the state step 4 ships in. The design's per-surface table gave grid 512 and pager unbounded: different `ResizeImageKey`s, two `ImageCache` entries, two decodes, on every tap (R9). One getter, three consumers, deleted table.

Note for modern rows the inline preview is already 300 px, so `ResizeImage(width: 512)` with `allowUpscaling: false` changes no pixels — only the key. That is precisely why it must come from the item, not the surface.

`memCacheHeight` / `ResizeImage.height` is **never set anywhere** (`media_decode.dart:10-14`). `BoxFit` shapes.

Add `kVaultTileMaxEdge = 400` to `media_decode.dart`, and **wire the four dead constants** — verified this session that `kZoomUpgradeScale`, `kZoomRevertScale`, `kThumbPrecacheRadius` and `kFilmstripDecodePx` have zero widget call sites (only `decode_identity_test.dart` asserts their ordering); `media_viewer.dart:87` uses a private `_warmRadius = 3` and the filmstrip at `:908-912` passes no `decodeWidth`. Wire or delete all four; `media_decode.dart` cannot be the shared contract while it is a file of aspirations. `kFileWarmRadiusMetered` stays unwired and is named as out of scope (§9).

### 3.3 Derivation

Reuse `Thumbnails._resizeJpeg` (`thumbnails.dart:83-107`) verbatim, including `bakeOrientation` (`:92`) and never-upscale (`:97-104`). This replaces `FlutterImageCompress.compressWithList` (`private_vault_repository.dart:239-244`): whether that path bakes EXIF orientation on these handsets is unverified, and a sideways tile above an upright full image is exactly the defect `thumbnails.dart:87-91` documents.

```dart
const int kVaultTileMaxEdge = 400;  // == Thumbnails._maxEdge
const int kVaultTileQuality = 72;   // == Thumbnails._quality
static Future<Uint8List?> forVaultTile(Uint8List bytes);      // bytes, not File — the
                                                              // vault has bytes in hand;
                                                              // forImage takes a File (:51)
static Future<Uint8List?> forVaultVideoTile(File decrypted);  // → forVideo (:67-79)
```

**Cost, stated:** `img.decodeImage` is pure-Dart `package:image`. The `~100 ms` at `thumbnails.dart:55` is the native path's figure and does not transfer. On a 12 MP JPEG expect seconds of a core and ~48 MB of isolate heap. It is isolated so it never drops a grid frame, but heal must be **hard-serialized across decode as well as upload** and idle-gated, not merely dwell-gated (§6).

**Video tiles are a real poster frame**, not the black box at `private_vault_screen.dart:495-504` — at upload time the picked `File` is in hand, so `Thumbnails.forVideo` costs nothing.

**Voice has no tile.** `tile_path` stays NULL, `kind == voice` renders a `surface2` tile with a duration chip and decrypts nothing. Today it falls through the note branch and paints empty text.

### 3.4 Decrypt threshold

- **Tiles and inline previews (≤ 256 KB) decrypt inline on the UI isolate.** `compute()` spawns a fresh isolate — tens of ms on an IN2015 plus two copies — against sub-millisecond XChaCha20 over 20 KB. Today `vault_media_cache.dart:110` spawns one isolate **per tile** with no cap; a first screenful spawns one per visible cell simultaneously.
- **Originals go through a new `CryptoCore.decryptBytesOffThread(Uint8List packed, {String? associatedData})`**, mirroring `encryptBytesOffThread:152-170`, taking `packFull` output **directly**. Not through `EncryptedPayload`, whose fields are base64 *strings*: the current shape (`vault_media_cache.dart:14-40`, `:105-111`) base64-encodes the downloaded blob to build the request and decodes it inside — +33 % allocation and two full passes per view.
- **The isolate argument is a `TransferableTypedData`.** `compute` copies its argument at spawn; a 13 MB blob costs downloaded + copy + plaintext ≈ 39 MB peak, and at the 100 MB `_maxOriginalMediaBytes` ceiling (`:369`) ~300 MB on a 2 GB IN2015. One line each side. **Apply it to the existing `encryptBytesOffThread` too** — the write path has the same defect today.
- The zero-nonce / zero-MAC legacy branch (`crypto_core.dart:139-140, 215`) is preserved on the read path **forever** — one production row depends on it.

`DecryptRequest` and `_isolateDecrypt` (`vault_media_cache.dart:14-40`) are deleted.

### 3.5 Two queues, not one

The design's single queue at concurrency 2 carries jobs dominated by a **network fetch** on a cold open — 24 tiles is 12 sequential waves, ~1.8 s, not "roughly a second". Supabase storage is HTTP/2.

- **`VaultFetchQueue`, concurrency 6.** `isWanted` checked immediately before issuing. `getFileFromCache` short-circuits before a slot is even taken.
- **`VaultDecodeQueue`, concurrency 2.**
- Every job carries `bool Function() isWanted`, **re-read at dequeue, never captured** — the discipline of `media_viewer.dart:260-262` applied to a grid. Cells register interest; they do not own work. Every failure is logged, never surfaced as a frame.

`flutter_cache_manager` fetches are not cancellable mid-flight, which is why the network cap is 6 and not 2: two in-flight jobs for items 0–1 must not block the six cells at index 90.

**Warm window and `cacheExtent` must agree.** `GridView`'s default `cacheExtent` is 250 logical px ≈ 1.85 rows at 134.5 dp; a ±4-item window is 1.33 rows, so cells build, register, get dropped as out-of-window, and re-register at the scroll edge — adding a round trip exactly where the warm-ahead was supposed to hide it. Set the window to **±18 items (6 rows)** and `cacheExtent` to 3 rows.

### 3.6 Failure classification — nothing renders `$e`

Classified **where the decrypt happens**, not at the widget. Today four places print the raw exception: `vault_media_viewer.dart:168`, `private_vault_screen.dart:87`, `:276`, `:320-324`.

```dart
sealed class VaultFailure {}
class KeyNotYetShared extends VaultFailure {}  // StateError, crypto_core.dart:219
class KeyGoneForever  extends VaultFailure {}  // MAC failure ON THE INLINE ciphertext only
class MediaTransient  extends VaultFailure {}  // 403 surviving one refresh; any MAC failure
                                               // on a tile or an original after the
                                               // ad_scheme retry
class MediaMissing    extends VaultFailure {}  // 404 on the ORIGINAL only
```

**`KeyGoneForever` is reachable only from a MAC failure on the row's inline ciphertext** — its AD is unambiguously `'$ad'` and the bytes arrived over TLS from Postgres, not from a disk cache. A MAC failure on a tile or an original is produced identically by a truncated download, a byte-flipped cache entry, a swapped `ad_scheme`, or a wrong AD, and must never earn a photo a permanent "it can't be opened here — or on hers" (Critique 3, #7).

**A tile 404 is not a failure.** `tile_path` non-null + 404 → treat exactly as `tile_path == null`: fall through to the inline preview, which is still readable in Postgres. The bounded inline query must therefore be **re-runnable per item**, not once at load (Critique 3, #6).

**An empty decrypted blob is not a failure either** (R10). Rule: `kind == video && !hasInline` → paint poster chrome (`surface2` + play glyph), never touch the inline preview and never construct `MemoryImage(Uint8List(0))`. Same for any row whose decrypted inline is zero-length. This is also the shape every heal-shrunk row takes (§2.1), so it is the common case after migration, not an edge case.

Copy:

- `KeyNotYetShared` — *"Waiting for your partner. This opens by itself once she's opened Closer on her phone."* Retries silently on the next `ensureSharedKey`.
- `KeyGoneForever` — *"Locked to an old install. This was encrypted with a key that was on your phone before you reinstalled. It can't be opened here — or on hers."* `[ Set up recovery ]`.
- `MediaTransient` — *"Couldn't reach this. Try again."*
- `MediaMissing` — *"This item's file is missing."*

And **`CloserLoadResult.unreadableMessage` gets wired** (`closer_load_result.dart:170-184`): today the repository counts unreadable rows (`:188-201`) and the screen reads only `result.items` (`:331-333`), so a vault whose every row failed renders the first-run empty state — exactly the failure `closer_load_result.dart:5-14` was written to prevent, and exactly what R1 would have shipped.

### 3.7 The two queries

```dart
// A — metadata, no ciphertext, deleted filtered server-side. ~300 B/row.
.from('vault_items')
.select('id,couple_id,kind,nonce,ad,ad_scheme,created_by,created_at,retention,'
        'reconfirm_due,delete_requested,delete_requested_by,delete_requested_at,'
        'storage_path,tile_path,media_mime_type')
.eq('couple_id', coupleId).eq('deleted', false)
.order('created_at', ascending: false).limit(300)

// B — bounded inline, only for rows that still need it. Re-runnable per item.
//     Today: 2 notes + 3 legacy photos ≈ 766 KB. After heal: ~100 B.
.from('vault_items').select('id,ciphertext,nonce')
.inFilter('id', needInline)   // kind in (note,trace) OR (photo && tile_path == null)
```

`kind == video` is never in `needInline` — its inline blob is 16 bytes of nothing.

**Realtime becomes a delta**, a `postgres_changes` channel filtered on `couple_id` (Realtime cannot do compound filters). **The handler must drop `deleted == true` itself** — `.eq('deleted', false)` only covers the initial select, and a soft delete arrives as an ordinary UPDATE. A delta that adds or changes a row recomputes `needInline` for that row only.

Note decrypts are batched into **one** pass returning `Map<String,String>`, memoized on `(keyEpoch, itemId, cipherHash)` — not `(keyEpoch, itemId)`, or a realtime UPDATE carrying new ciphertext stays hidden until process restart.

---

## 4. The pager

### 4.1 Tap to first pixel

The tile's provider is already resident in L3 at the moment of the tap. The pager mounts a **`Hero`** (unconditionally, with an offstage tag for non-current pages — conditioning it changes the widget *type* at that slot and restarts a finished decode, `media_viewer.dart:571-583`) and its underlay is the **identical provider instance from L2 at the identical `tileDecodeWidth`**. Tap-to-first-pixel is a composite, not a load.

It is a **soft** composite: 400 px `BoxFit.contain` into a 1080 px viewport is a 2.7× upscale held for the whole original download. "Instantly soft, then sharp" is the claim; "instant" is not.

Today the pager blanks to a spinner (`vault_media_viewer.dart:121-133`) and never touches the preview it already decrypted.

### 4.2 The underlay is a layer, not a placeholder

```
Stack
 ├ tile layer   provider from L2, item.tileDecodeWidth, BoxFit.contain, fade in 0 / out 0
 ├ full layer   ResizeImage(MemoryImage(fullBytes), width: viewportPx), fade in 150 / out 0
 └ failure      a muted panel drawn OVER a picture that stays visible
```

As a placeholder the tile is unmounted the instant the full resolves **or errors**, replacing a soft-but-correct photo with a grey card.

**Any indicator is gated on `kIndicatorDelay` (400 ms) AND on "nothing has painted yet"** — never on "we are loading". With an underlay present no spinner is ever allowed.

### 4.3 Neighbour warming

```
distance 1    original bytes → L1 → decrypt → precacheImage at the IDENTICAL viewportPx
distance 2-3  original bytes → L1 only, never decoded
videos        NEVER warmed at any distance
```

One `_warming` flag: ten fast swipes start one loop, not ten. The index is **re-read after every await**, never captured; `if (!mounted) return` after every await. Distance 1 must use the same `ResizeImage` width the page will use — a different width is a different key and discards a finished frame (the exact bug fixed at `media_viewer.dart:506-515`). Swiping away drops the in-flight original via `isWanted`.

Today `_prefetchAround` (`vault_media_viewer.dart:35-41`) warms ±1 **originals** with no decode, no cancellation and no video exclusion — for the current vault, speculatively pulling 13 MB.

### 4.4 Mechanics

`allowImplicitScrolling: true`. Physics swapped to `NeverScrollableScrollPhysics` while zoomed — the gesture arena resolves pan-vs-page wrongly 100 % of the time because `kTouchSlop` 18 px beats `kPanSlop` 36 px (`media_viewer.dart:131-136`). `_maxScale 5.0`, `_doubleTapScale 2.5` anchored on the tap point, `_zoomEpsilon 1.01`.

### 4.5 Zoom upgrade

Above **`kZoomUpgradeScale` 1.5** mount an unbounded `MemoryImage(fullBytes)` above the bounded layer; unmount below **`kZoomRevertScale` 1.2** **and explicitly `imageCache.evict` its key on unmount**. Deliberately unequal thresholds. The bytes are already in L2, so the upgrade is one decode and no network. Today `InteractiveViewer(maxScale: 4.0)` over `Image.file` (`:135-141`) magnifies whatever was decoded, at source resolution.

### 4.6 Video

The poster tile is the underlay and paints instantly. The original must still download and decrypt in full before frame 1 (13,047,338 B today, up to 100 MB) — XChaCha20-Poly1305 over a whole file is not seekable.

- **Real download progress over the poster**, not a spinner. The progress source is `CacheManager.getFileStream(withProgress: true)` on L1 — which is why the ephemeral L1 ban had to go (§5.4): under it an ephemeral video would have had a spinner, the exact thing this bullet exists to remove.
- Video originals download **on tap only**, never warmed, never precached.
- On first successful decrypt, derive the poster with `Thumbnails.forVideo` and heal `tile_path` — free, the file is already there.

---

## 5. Decrypted-cache security policy

### 5.1 What is actually true today

**Correction to the design (R4):** raising the disguise returns a different `MaterialApp` (`main.dart:586-600`), unmounting the router subtree — `main.dart:421` says so in its own comment — so `PrivateVaultScreen.dispose()` **does** run and `VaultMediaCache.clear()` **is** invoked. "Decrypted photos survive the disguise" as stated is wrong.

What is real, ranked:

**(a) The orphan class — permanent, unbounded, and the highest-value item in this section.** `_write` names files `vault_${_sessionId}_${role}_${item.id}.$ext` where `_sessionId` is per-**process** (`vault_media_cache.dart:51`), `_files` is in-memory only, and **there is no startup sweep anywhere** in the app. Any file whose delete does not complete is unreachable by every future process. Three ways it happens: the `clear()` race (`:157-159` clears `_files` synchronously while a pending `_write` registers into the cleared map at `:118-124` — that file is never deleted at all); `unawaited(clear())` firing during the pause transition, N async `exists`+`delete` round trips against an unguaranteed kill window; and `detached`, where the engine is being torn down. Full-resolution decrypted JPEG/MP4 accumulates in `cacheDir` for the life of the install.

**(b) Process kill without a cover raise.** LMK reclaims a backgrounded app hours later; `detached` is not reliably delivered. Nothing runs.

**(c) `FLAG_SECURE` is on the viewer (`vault_media_viewer.dart:30`) but not on the grid** — verified, no `SecureScreen` import in `private_vault_screen.dart`. The recents-apps snapshot of the vault grid is captured by the OS. **The cover cannot win this race**: Android captures the thumbnail during the stop transition, while `showRealApp.value = false` needs a Dart frame plus a raster pass. `FLAG_SECURE` on the grid is the only thing that reliably prevents it, not belt-and-braces.

**(d) The wipe hook is on the wrong branch.** `main.dart:266-268` sits inside `if (!MilesApp.systemOverlayActive)`. Attach the wipe there and every backgrounding during a picker skips it — including swiping the picker away to home, where the `finally` that clears the guard may not run.

### 5.2 The policy

**Photos and tiles never touch disk decrypted.** L1 holds ciphertext; plaintext exists only in L2 (RAM) and L3 (`ImageCache`). The design's "decrypt to disk keyed by item id" is the defect, not the fix.

**Video and voice must be a `File`** (`VideoPlayerController.file`, `vault_media_viewer.dart:223`). One directory, `${getTemporaryDirectory()}/vault_scratch/`, never loose files in the temp root. Files named `<itemId>.<ext>` — no `_sessionId`; the wipe is by directory, and a stable name lets a re-open within one foreground session reuse the file. **Hard cap: one file.** Decrypting a second video deletes the first.

**`VaultMediaCache.clear()` = L2 clear + `imageCache.clear()` + `imageCache.clearLiveImages()` + `vault_scratch/` directory wipe.** Ordered triggers:

1. **`main()`, before `runApp` — a blocking sweep of `vault_scratch/` plus a prefix sweep of `getTemporaryDirectory()` for stale `vault_*` files.** This is the one that closes (a), and it must run first because a process kill is exactly when nothing else does. Promote it from fifth to first.
2. **`await VaultMediaCache.clear()` at the top of the `paused | hidden | detached` handling in `main.dart`, ABOVE the `systemOverlayActive` guard.** The wipe is not the cover raise. There is no case where decrypted media should survive a background transition — the picker returns to a screen that re-decrypts from L1 ciphertext in milliseconds.
3. App lock / sign-out.
4. `CryptoCore.keyEpoch` **change** (not call — see §3.1).
5. `PrivateVaultScreen.dispose()` — kept, now awaited through a completer rather than `unawaited`.

**Ordering with ExoPlayer.** `VideoPlayerController.file` holds an open descriptor; unlinking while open leaves the inode live. `await controller.dispose()` **then** delete, which is why trigger 2 must be awaited rather than fire-and-forget. A video playing when the cover rises loses its controller and its file immediately; the user returns to the poster and taps again. Continuity loses to the wipe, deliberately.

**`SecureScreen` gets a Dart-side ref count.** The native side is a single `secureFlagSet` boolean (`MainActivity.kt:52-72`, verified wired — drop the "might be a silent no-op" caveat). Without a ref count, closing a photo (`vault_media_viewer.dart:46`) clears `FLAG_SECURE` on the still-visible grid. Apply to the grid, the viewer, and the note dialog's route.

### 5.3 What this does and does not claim

- **L1 ciphertext at rest is safe against the server, not against the device.** Postgres holds ciphertext without the key; the handset holds ciphertext **and** the key — the X25519 seed is in `flutter_secure_storage` with `encryptedSharedPreferences: true` and no `setUserAuthenticationRequired`, so the Keystore master key is available to the process after first unlock. A 90-day disk cache is still the right call, justified as *no worse than the key already being there*, not as parity with Postgres.
- **Unlink is not erase.** Deleting a decrypted 13 MB MP4 on f2fs leaves the blocks; overwrite-before-unlink is unreliable under wear levelling. "Bounded plaintext at rest" means bounded in the filesystem namespace. The only real fix is never writing the plaintext, which needs the chunked container in §9. The UI must not say files are erased.
- **adb backup is genuinely closed** — `allowBackup="false"`, `fullBackupContent="false"`, and `data_extraction_rules.xml` excludes `root/file/database/sharedpref/external` for both `cloud-backup` and `device-transfer`; release builds are not debuggable so `run-as` is out. Residual: OEM transfer tools and root, neither addressable in Dart.
- **`Diag` writes to `getApplicationDocumentsDirectory()/diag.ndjson`** (`diag.dart:107, 226`) — persistent, outside `cacheDir`, untouched by every trigger above. Audit `DiagRedact` (`diag_event.dart:98`) for vault item ids and storage paths **before** adding any diag call to this path. Not audited this session.

### 5.4 Ephemeral items

The blanket L1 ban is **dropped**. It cost half the vault a re-download every session (verified: `317a0442`, `5746a8e1`, `fe442503`, `594466eb`, `241cfdb0`) in exchange for protection against an expiry mechanism that does not exist (R8), and it forced a spinner onto ephemeral video (§4.6).

Replaced by two things that do work:

- **`vault_expire_ephemeral()` on cron** (§2.4). `reconfirm_due` becomes real.
- **L1 `maxAge` clamped per entry** to `reconfirm_due - now` for ephemeral rows, `Duration(days: 90)` otherwise. A cache entry can no longer outlive the item it caches.
- `vault_hard_delete` and the expiry delta call `VaultCipherCache.removeFile(tilePath)` and `removeFile(storagePath)` on both devices via the realtime delta.

### 5.5 Never write cleartext (R6)

The refusal guard belongs in `CryptoCore`, not in the vault's callers. Guarding only heal and the vault write path leaves Memory Threads, Afterglow, Body Map and Fantasy Jar on the silent-plaintext path.

```dart
// crypto_core.dart
static Future<bool> deriveSharedKey({required String partnerPublicKeyB64});
// returns false on EVERY fallback path: legacy literal, base64 failure, length != 32.

static Future<EncryptedPayload> encryptBytes(List<int> bytes,
    {String? associatedData, bool requireEncryption = false}) async {
  final key = _sharedKey;
  if (key == null) {
    if (requireEncryption) throw StateError('no couple key — refusing to encrypt');
    ...
  }
}
```

`ensureSharedKey` treats `false` identically to the `plaintext-v1` literal — the "Waiting for your partner" state already exists for it. **Fix or delete `closer_crypto.dart:14-15`'s "Idempotent: caches the result"**; it is false and 12 call sites read it.

Every Closer caller passes `requireEncryption: true`. Belt and braces at the upload boundary:

```dart
final k = await CryptoCore.exportSharedKeyBytes();
if (k == null) throw StateError('no couple key — refusing to upload');
final packed = packFull(payload);
if (packed.take(40).every((b) => b == 0)) throw StateError('refusing to upload cleartext');
```

**Why this is not optional.** Live, verified: `c6dce7e3` (photo, 323,077 B) and `33642090` (note, 39 B) have zero nonce and zero MAC — cleartext in production. `decryptBytes` short-circuits on `_isLegacy` and returns the plaintext **without needing a key**, so a heal pass with `_sharedKey == null` would successfully "heal" that row by uploading a cleartext JPEG to storage behind a signed URL. Those two rows are not history; they are a live detector for a bug that is still open. And a design cannot reject blurhash on server-operator grounds (§9) while leaving a server-operator-triggered plaintext downgrade in place — writing a 31-byte value into one member's `partner_keys.public_key` currently passes `ensureSharedKey`, nulls the key, and puts every subsequent vault write in cleartext under a UI that says "Encrypted end-to-end" (`private_vault_screen.dart:305`).

---

## 6. Migration of existing rows

**Nothing can be backfilled server-side.** Only the couple's devices hold the key. `ciphertext` is `bytea not null` and stays in the schema permanently.

**Ledger, blocking.** Migrations here apply through `apply_migration`, not `supabase db push` — the repo files are a mirror. Confirmed by divergence: live policies are `intimate_select`/`intimate_insert`/`intimate_delete`, while `20260601006300_closer_reliability.sql:60-83` creates `closer_intimate_media_read`/`_upload`/`_delete`. That file's effect is **not** live. Apply V-A/V-B/V-C by name, mirror the files, reconcile or retire `20260601006300` before anyone runs `db push`.

### 6.1 `vault_heal.dart`

Shaped like `thumb_backfill.dart:25-101`: upload **then** claim, one row at a time, **serialized across decode as well as upload**, gated on the grid being idle ≥ 2 s, a failure not retried this session, reading bytes that are already local wherever possible. The §5.5 refusal guard runs first, unconditionally.

| class | live rows | action |
|---|---|---|
| **modern photo, `storage_path` set** | 5 (`317a0442`, `5746a8e1`, `5a735df3`, `8a03c7db`, `fe442503`) | Pull the original from L1 (usually cached), `Thumbnails.forVaultTile`, upload `vault/t/$id.enc` with AD `'v2\|$id\|$ad\|tile'`, `update … set tile_path`. The inline 300 px preview is **not** the source — never upscale 300→400. |
| **video** | 1 (`f9853e45`) | Poster derived on first playback decrypt (§4.6). Never a speculative 13 MB download. |
| **legacy photo, `storage_path` NULL** | 3 (`da987554` 221,384 B, `594466eb` 221,384 B, `c6dce7e3` 323,077 B) | The inline ciphertext **is** the original. Decrypt inline with AD `'$ad'` → derive tile → upload `vault/t/$id.enc` **and** upload the full to `$coupleId/vault/$ad.enc` → set `tile_path` **and** `storage_path`. `ad_scheme` stays 1 — the AD of the bytes being re-uploaded is unchanged. **This is also the fix for the three rows that cannot be opened at all today**: `_downloadAndDecryptOriginal` 404s twice (`vault_media_cache.dart:85-100`) while the full-resolution image sits in the row the grid just decrypted. |
| **note** | 2 (`241cfdb0` 18 B, `33642090` 39 B) | Nothing. Their `ciphertext` is never shrunk and stays in query B forever. |

`c6dce7e3` is cleartext (zero nonce, zero MAC). Heal re-encrypts it as a side effect of the legacy path — **only** because the §5.5 guard has already proven a real key exists. Without the guard, heal is a propagation mechanism, not a remediation.

**Delete the unreachable fallback** at `vault_media_cache.dart:92-100`: `'vault/${item.ad}.enc'` has `'vault'` as its first path segment, not the couple id, so no policy can ever permit it.

### 6.2 The shrink pass — separate, later, and read-back verified

Runs only on rows where `storage_path IS NOT NULL AND tile_path IS NOT NULL AND kind IN (photo, video)`. For each, in order:

1. Download **both** objects and confirm both MAC-verify (for the original, honouring the §2.3 `ad_scheme` retry).
2. Only then `update vault_items set ciphertext = <its own first 16 bytes>`.

For `da987554`/`594466eb`/`c6dce7e3` the inline blob is the **only** copy of the photo. Shrinking before the storage upload is confirmed by read-back destroys it. This is why the shrink is a separate pass at build step 7, not part of heal.

After shrink, `hasInline` is false and the row falls into the §3.6 empty-blob rule — which is the same branch the video row already needs, so it is one rule, not two.

### 6.3 Rows whose key was destroyed

Detected as a MAC failure **on the inline ciphertext only** (§3.6). Heal must:

- never retry in a loop — a `_seen` set like `thumb_backfill.dart:46`, **plus** a marker in `SharedPreferences` keyed `'vault_unreadable|${CryptoCore.keyEpoch}|$itemId'`;
- rely on `keyEpoch` being a **hash of the key material** (§3.1), or the marker cannot work: a `static int` starting at 0 every launch never matches across sessions and collides within them, and "an escrow restore clears every one of them for free" is only true for a content-derived identity;
- **not** write anything server-side — unreadability is per-device, and the partner may hold the key.

The grid paints `KeyGoneForever`'s muted panel for those rows: not a spinner, not a retry button that can never succeed, not `$e`.

---

## 7. File-by-file plan

### Shared with `docs/guides/memory-threads-spec.md` — implement ONCE

These are not vault code. Whichever feature lands first owns them; the other consumes them. **Where this spec differs from the Memory spec's text, this spec is the corrected version and the Memory spec must be amended in the same commit.**

| item | shared how | difference from the Memory spec |
|---|---|---|
| `CryptoCore.keyEpoch` | one field, both caches key on it | **Changed:** Memory §3.2 specifies `static int` bumped per call. That is wrong (R5). It becomes a hex digest of the key material. Memory's §3.2 text must be amended. |
| `CryptoCore.decryptBytesOffThread(Uint8List packed, …)` | one function | **Added:** `TransferableTypedData` for the argument, and the same fix applied to the existing `encryptBytesOffThread`. |
| `deriveSharedKey → bool`, `ensureSharedKey` hard failure, `encryptBytes(requireEncryption:)`, the refuse-cleartext guard | one change in `crypto_core.dart` + `closer_crypto.dart` | **Moved:** Memory §3.9 puts the guard in the upload path and in `memory_heal.dart`. It belongs in `CryptoCore` so Afterglow, Body Map and Fantasy Jar are covered too. |
| `media_decode.dart` constants + **wiring** `kZoomUpgradeScale` / `kZoomRevertScale` / `kThumbPrecacheRadius` / `kFilmstripDecodePx`, and the zoom layer in `chat/widgets/media_viewer.dart` | one commit, fixes chat | **Extended:** Memory names two dead constants; four are dead (verified). |
| The `tileDecodeWidth`-on-the-item rule | `media_source.dart:80` pattern, now three consumers | **New ruling** (R9). Memory §3.5's per-surface table has the same latent split for its gallery grid vs pager underlay and should adopt the getter. |
| L2-owns-providers + `imageCache.evict(…, includeLive: true)` on eviction | one discipline, two caches | **Corrected:** `evict` takes a **key**, so the entry must track every provider it handed out, not just the `MemoryImage`. Memory §3.3 as written misses `ResizeImage`-wrapped entries. |
| L1 pattern: own named `CacheManager`, static singleton, `getFileFromCache` before signing, `putFile(path, …)` so no signed URL is persisted | two stores (`milesVaultCipher`, `milesMemoryCipher`), one implementation | **New** (R12). |
| `MediaUrls` single-flight `Map<String, Future<void>>` in `warm` | `media_urls.dart` | **New.** Verified `warm` (`:65-81`) filters on `cached()` with no in-flight map, so overlapping warms during a fling issue N concurrent `createSignedUrls`. |
| Two queues (fetch 6 / decode 2) with dequeue-time `isWanted` | one implementation, two instances | **Changed:** Memory §3.7 specifies one queue at 2. |
| `Thumbnails` additions + `_resizeJpeg` reuse | `thumbnails.dart` | Vault needs a **bytes** entry point; `forImage` takes a `File`. |
| `storage_reap` + **never `delete from storage.objects`** | one ruling | **Corrects Memory §2.4 and `20260601003400`, both of which contain the same impossible reaper** (R3). Fix them here. |
| Consent-RPC shape + dropping `*_delete_member` | `001400`'s `do $$` loop created identical policies for `vault_items`, `afterglow_entries`, `couple_dissolutions` | Memory §11 already flags "the same DELETE hole on the vault". V-B is that fix. |
| Sealed failure classification + `unreadableMessage` wiring | one sealed type in `core/`, per-feature copy | **Corrected:** `KeyGoneForever` only from an **inline** MAC failure (Critique 3, #7). |
| `SecureScreen` ref counting | `secure_screen.dart` | **New** (R11). Also: the "silent no-op if `MainActivity` isn't wired" caveat is false — it is wired; delete it from both specs. |
| `main.dart` wipe hook **above** the `systemOverlayActive` guard + startup sweep in `main()` | one handler | **Corrected placement** (§5.1(d)). Memory §3.3 says "`main.dart`'s cover handler (~:268)" — that line is inside the guard. |
| Ledger step −1 | one reconciliation | Same in both. |

### New — vault only

| file | what |
|---|---|
| `supabase/migrations/…_vault_tiles_and_wire.sql` | §2.4 (V-A) |
| `supabase/migrations/…_vault_consent_rpcs.sql` | §2.5 (V-B) |
| `supabase/migrations/…_vault_publication_columns.sql` | §2.6 (V-C) |
| `mobile/lib/features/closer/private_vault/vault_cipher_cache.dart` | L1, singleton, path-keyed, `getFileFromCache` first, `putFile` with path-as-url, 403→refresh-once, per-entry `maxAge` |
| `.../private_vault/vault_media_cache.dart` | **rewritten in place** — L2 LRU keyed `'${keyEpoch}\|$path'`, hands out providers and tracks them, scratch-dir lifecycle, `clear()` semantics of §5.2 |
| `.../private_vault/vault_queues.dart` | fetch 6 / decode 2, dequeue-time `isWanted` |
| `.../private_vault/vault_failure.dart` | §3.6 classification + exact copy |
| `.../private_vault/vault_heal.dart` | §6.1 |
| `.../private_vault/vault_shrink.dart` | §6.2 |
| `.../private_vault/widgets/vault_tile.dart` | keyed, no spinner, `surface1` miss, poster chrome for video |
| `.../private_vault/widgets/vault_photo_page.dart` | §4.2, §4.5 |

### Modified — vault only

| file | change |
|---|---|
| `private_vault_repository.dart:126-160` | `ciphertext`/`mac` nullable; `containsKey` gate; `hasInline`; `tileDecodeWidth`; `deleteState` from `delete_age_s` |
| `:180-203` | `.stream()` → query A + query B + `postgres_changes` delta; **delta handler drops `deleted == true`**; `.eq('deleted', false)` server-side |
| `:114-118` | delete the `payload` getter's per-access `base64Encode`; expose raw packed bytes |
| `:208-304` | client-minted v4 id; `Thumbnails.forVaultTile` replaces `FlutterImageCompress` at `:239-244`; upload `t/$id.enc` with `'v2\|$id\|$ad\|tile'`; `ad_scheme: 2`; `requireEncryption: true`; strict order derived-objects → row, with the compensating `.remove()` at `:294-303` extended to the tile |
| `:308-357` | three mutators → `rpc()`; **keep the client-side `storage.remove()` at `:349-351`** |
| `:388-390` | **delete `decryptVaultBytes`** — zero callers, verified |
| `private_vault_screen.dart:42-60` | key derivation parallel with the query |
| `:316, :327-328, :507-513` | all three spinners deleted; grid lays out over an empty list |
| `:334-361` | `key: ValueKey(item.id)`; tile extracted; Hero tag; `cacheExtent` = 3 rows |
| `:495-505` | video paints its poster; `Image.file` → L2 provider |
| `:331-333` | `unreadableMessage` wired ahead of `_EmptyVault` |
| `private_vault_screen.dart` | `SecureScreen.setSecure()` on the grid and the note dialog |
| `vault_media_cache.dart:14-40` | `DecryptRequest` / `_isolateDecrypt` deleted |
| `vault_media_cache.dart:92-100` | unreachable `vault/${ad}.enc` fallback deleted |
| `vault_media_viewer.dart:35-41, 57-71, 100-141, 218-234` | underlay layer, `kIndicatorDelay` gate, asymmetric warm, cancellation, zoom layer, `allowImplicitScrolling`, physics swap, poster + real progress |
| `media_source.dart:78` | correct the stale "already ~720px" comment |

---

## 8. Tests

### Widget / unit — `flutter test`, no device

There is **no test file under `mobile/test` covering the vault read path today**.

1. **`fromJson` parses the exact projection.** Feed query A's literal column list to `VaultItem.fromJson` and assert it succeeds with `hasInline == false`. *This single test is what R1 was.* Assert it also still throws on a genuinely-null `ciphertext` value.
2. **Decode identity.** Grid tile provider and pager underlay provider are `==` for one item, at both `tile_path` states. Assert provider **equality**, not a constant's value — a stray `height:` passes a constant test.
3. **L2 instance identity.** Two `get()` calls for one path return the **identical** `Uint8List`.
4. **Cache keys.** `tileKey != fullKey`; two different signed URLs for one path yield one key; the key is path-derived and epoch-prefixed.
5. **Eviction walks every provider.** L2 eviction of an entry that handed out both an unbounded and a `ResizeImage`-wrapped provider evicts **both** keys, `includeLive: true`. Assert against a fake `ImageCache`.
6. **Epoch identity.** `keyEpoch` is stable across two `deriveSharedKey` calls with the same partner key (so navigating Closer → Vault does **not** wipe), and changes when the key material changes. Assert `clear()` fires only on the latter.
7. **AD strings frozen, per slot.** Golden assertion on `'v2|$id|$ad|tile'` and `'v2|$id|$ad|full'`; on a **scheme-1 row**, `tileAd == 'v2|$id|$ad|tile'` **and** `originalAd == ad` **and** `inlineAd == ad`. The design's ambiguity here was unrecoverable if implemented the other way.
8. **`ad_scheme` is a hint.** A scheme-1 row whose `ad_scheme` was flipped to 2 still decrypts via the retry, and classifies as `MediaTransient` — never `KeyGoneForever` — if both candidates fail.
9. **Refuse cleartext, three ways.** `encryptBytes(requireEncryption: true)` with a null key throws; a packed blob whose first 40 bytes are zero throws; `deriveSharedKey` returns `false` for a 31-byte key and `ensureSharedKey` throws on it.
10. **Heal does not propagate plaintext.** A zero-nonce/zero-MAC row with no key: heal is a no-op, not a successful upload.
11. **Legacy inline round-trip.** A zero-nonce/zero-MAC `ciphertext` still opens and paints, bounded at `kTileDecodePx`.
12. **Legacy row becomes openable.** `storage_path` NULL + inline bytes heals to both `tile_path` and `storage_path`, and the pager reads it.
13. **Shrink is read-back gated.** Shrink refuses when either object 404s or fails its MAC; after a successful shrink the row renders from its tile and never constructs `MemoryImage(Uint8List(0))`.
14. **Empty inline blob.** A 16-byte `ciphertext` (the `f9853e45` shape) produces poster chrome for video and the muted panel for anything else — never a decode exception.
15. **Tile 404 falls through to inline**, before any failure panel, and the per-item inline query is re-runnable.
16. **`KeyGoneForever` is inline-only.** MAC failure on a tile or an original → `MediaTransient` and **no persisted marker**; MAC failure on inline → `KeyGoneForever` and a marker keyed on the epoch digest.
17. **No `$e` anywhere.** `StateError` → `KeyNotYetShared`; 403-after-refresh → `MediaTransient`; 404 → `MediaMissing`; and **no produced string contains the exception's `toString()`**.
18. **Empty ≠ unreadable.** `items: []` with `unreadable: 3` renders `unreadableMessage`, not `_EmptyVault`.
19. **L1 maxAge is clamped** for an ephemeral item to `reconfirm_due - now`, and is 90 days for `keep`.
20. **Delete invalidates the cache** on both the acting and the receiving device (delta path), for both `tile_path` and `storage_path`.
21. **The delta drops soft deletes.** A `postgres_changes` UPDATE with `deleted = true` removes the row from the list.
22. **Expiry uses the server clock.** A device 30 days fast, reading `delete_age_s`, must not offer force-delete.
23. **Action matrix.** Table-driven over 3 delete states × {requester, partner} × {<14 d, ≥14 d}. `private_vault_screen.dart:206-246` has no test at all.
24. **Queues.** Enqueue 95 jobs, move the visible range: off-screen jobs never run, visible ones complete first. ≤ 2 decode in flight, ≤ 6 fetch in flight.
25. **`upsert` is never passed.** A recording storage fake asserts no vault upload sets `upsert: true`, and a 409 produces `remove` → `uploadBinary`.
26. **Column hygiene.** Extend `test/unit/hygiene/repo_hygiene_test.dart` to diff every column the vault repository writes against a schema snapshot **and** against V-B's grant list — an ungranted write is a test failure, not a runtime 403. `ad_scheme` must appear in the insert and never in an update.

### Device-only — IN2015 / Vivo / OnePlus7, not assertable in CI

- **Time to first tile on a cold open of 100 items, and whether any indicator ever appears.** The headline claim.
- Whether a spinner appears while flinging at 60/90 Hz — needs a real raster thread.
- **Real AOT-release cost of an inline 20 KB decrypt vs an isolate hop.** The empirical basis for the 256 KB threshold; every timing figure inherited from the Memory research was measured on Windows x64 under the JIT VM, an optimistic lower bound.
- **Real AOT cost of `Thumbnails._resizeJpeg` (pure-Dart `package:image`) on a 12 MP JPEG from these handsets' cameras.** This is what sizes heal's idle gate, and the `~100 ms` in `thumbnails.dart:55` is the native path's number.
- **`ls /data/data/com.miles.miles/cache/vault_*` on a rooted IN2015 before any of this work**, to size the orphan class (§5.1a) empirically. One command, and it settles whether trigger 1 is urgent or merely correct.
- **After an OS process kill from backgrounding: `vault_scratch/` empty and `getTemporaryDirectory()` free of `vault_*`.** The claim §5 rests on.
- After raising the cover mid-playback: controller disposed **then** file gone, awaited.
- `FLAG_SECURE` on the grid, and the ref count surviving a viewer open/close cycle.
- Peak RSS with L2 full and the grid open; `ImageCache` not exceeding budget across a scroll→tap→pinch→back sequence.
- Two-device realtime after V-A's `replica identity default`: whether the delete-request toggle on `c6dce7e3` now propagates. Arithmetic says it currently cannot — FULL replica identity ships ~646 KB of hex twice, ~1.29 MB against Realtime's 1 MB default `max_record_bytes`. Delete-consent on the largest row has near-certainly never worked.
- **Both phones on build 15 before V-C is applied.** Not a test, a gate.
- `Thumbnails.forVideo` on a decrypted MP4 from `vault_scratch/`.
- Whether `createSignedUrls` accepts 24 paths in one request without a server-side cap.

---

## 9. Out of scope, and why

- **Streaming / chunked video decrypt.** A seekable container (per-64 KB frame AEAD with a counter in the AD) is a wire-format change to `packFull` affecting every Closer feature at once. Until it exists a 13 MB video is a 13 MB download before frame 1, and it is also the only thing that would make §5.3's "unlink is not erase" moot. The poster underlay and real progress are the honest mitigation, not a fix.
- **Draining `storage_reap` through the Storage API.** The ledger, trigger and client-side `remove()` ship now. A service-role edge function is named, not pretended away. **`delete from storage.objects` is not a fallback** — it is blocked by `protect_delete` and would make the blob permanently unreachable even to the future edge function.
- **Server-side backfill.** Impossible in principle. `ciphertext` stays in the schema permanently.
- **Metered-connection branching.** `kFileWarmRadiusMetered` stays unwired and there is no connectivity package in `pubspec.yaml` — verified.
- **Re-ADing existing originals to containment binding.** Requires re-encrypting and re-uploading every original from a device holding the key. Residual stated in §2.3.
- **Voice waveforms.** Voice gets a duration chip and nothing else here.
- **Strengthening `KeyEscrow`** (single HKDF-SHA256 over the raw password, no iteration count) and **replacing the PIN hash** (unsalted 32-bit FNV-1a over 10,000 values). Both real defects, both cross-cutting across every Closer feature.
- **Out-of-band key verification UI / TOFU pin.** The Memory spec §3.9 introduces a partner-key pin; the vault consumes it if it exists but does not gate on it.
- **iOS.** `FLAG_SECURE` has no equivalent (`secure_screen.dart:11-12`) and the disguise machinery is Android-shaped.
- **A plaintext blurhash or thumbnail hint for instant cold paint.** Rejected deliberately: a low-resolution copy of an intimate photo, stored where anyone with database access can read it, in a feature whose entire promise is the opposite. The prefetch is the answer, and it is weaker on a genuinely cold device — the correct trade, stated out loud rather than quietly buying smoothness with the thing the feature protects.

---

## 10. Build sequence

Ordering is inverted from the design in two places, both forced: the client must precede the wire change (R2), and heal must precede any narrowing of what the query carries (R1).

| # | step | why here |
|---|---|---|
| **−1** | **Reconcile the ledger.** Apply by name via `apply_migration`; retire the `db push` path; reconcile or retire `20260601006300`. | Verified divergence: live policies are `intimate_*`, `006300`'s `closer_intimate_media_*` never applied. Ten minutes. |
| **0** | **Migration V-A.** Columns, index, `replica identity default`, ephemeral expiry cron, reap **ledger** (no SQL deleter), `revoke select from anon`. | **Zero client change and safe for build 14** — `DEFAULT` only shrinks `old_record`, which `SupabaseStreamBuilder` needs only for a DELETE's PK. Immediately stops shipping the inline ciphertext twice per UPDATE and brings `c6dce7e3` under `max_record_bytes`. |
| **1** | **Crypto core.** `keyEpoch` as a key digest; `deriveSharedKey → bool`; `ensureSharedKey` hard failure; `encryptBytes(requireEncryption:)`; `decryptBytesOffThread` + `TransferableTypedData` on both directions; fix the false doc comment. | Shared with Memory Threads. Closes the live plaintext-downgrade path (R6) and is a prerequisite for every cache invariant below. Small, testable, no UI. |
| **2** | **Honest failures + security surface.** `vault_failure.dart`, `unreadableMessage` wired, every `$e` deleted, `SecureScreen` ref count + grid + note dialog, **startup sweep of `vault_scratch/` and stale `vault_*` in `main()`**, wipe hook moved above the `systemOverlayActive` guard. | Mostly text and two hooks. Closes the recents-snapshot leak and the orphan class — the only *permanent* plaintext-at-rest exposure in the feature. Ships before any cache work because it is independent of it. |
| **3** | **Model tolerance + the two queries + realtime delta.** Nullable `ciphertext`, `containsKey` gate, `tileDecodeWidth`, query A + bounded query B, delta handler that drops soft deletes, `delete_age_s`. | ~60 lines. 1.6 MB → ~30 KB + ~766 KB bounded, and **the vault still renders every row**. This is the step R1 would have broken. |
| **4** | **`VaultCipherCache` + `VaultMediaCache` + the two queues + the scratch-dir lifecycle.** | The load-bearing infrastructure. Everything after consumes it. **Commitment point.** |
| **5** | **Grid repaint.** Keyed tiles, no spinners, one `tileDecodeWidth` per item, warm-24, `cacheExtent` matched, poster chrome for video, empty-blob rule. | The complaint, answered. Visibly done here even before a single tile object exists — the inline preview flows through the new cache at the item's own width. |
| **6** | **Pager.** Underlay layer, Hero, asymmetric warm, cancellation, zoom upgrade layer with explicit evict (also fixes chat), video poster + real progress. | Trivial once L2 hands out providers. |
| **7** | **Tile derivation on the write path** + `Thumbnails.forVaultTile` + client-minted id + `ad_scheme: 2` + the per-slot AD table. | New items get real tiles. Write path only; the read path already handles both schemes. |
| **8** | **`vault_heal.dart`**, then **`vault_shrink.dart`** as a separate pass. | Retrofits the 8 photo rows and **unbricks the 3 that cannot be opened at all**. Shrink runs only after read-back proves both objects exist — for three of those rows the inline blob is the only copy of the photo. |
| **9** | **Migration V-B + the RPCs.** Ship the client that calls them in the same build, or earlier. | Dual consent stops being a client `if`. Applied before that client, build 14's delete flow 403s permanently on a phone with no update channel. |
| **10** | **Migration V-C — the publication column list.** Only once both handsets are verified on build 15. | Under a column list, `SupabaseStreamBuilder` on build 14 replaces cached rows with a `newRecord` that has no `ciphertext`, and rows silently vanish from the grid until an app restart. |

Steps −1 through 5 are independently shippable and each improves the current screen without touching its layout.

---

## Unverified

Everything above is derived from source and from live schema/policy/trigger/row/object queries run this session. **Not** measured: wall-clock timings, frame traces, or peak RSS on any device — the app was not run. The claims that a grid of 100 paints without a spinner, and that tap-to-first-pixel is one composite, are mechanical consequences of the design (layout independent of media; one provider instance at one width already resident in L3), not observations. §8's device list is what turns them into facts. The Realtime `max_record_bytes` figure is the Supabase default, not read from this project's config. `DiagRedact`'s coverage was not audited.

---

## The single most likely reason it still feels slow on his phone

Everything above removes bytes and decodes. What none of it removes is a **serial chain of network round trips before the first tile byte can move**: session refresh → the metadata query → `createSignedUrls` → the object fetch. Only the last is parallel across tiles; the first three are strictly ordered, each a full RTT to the Supabase region, and `MediaUrls.warm` cannot even be *called* until the metadata query returns. On his handset that is realistically 600–900 ms of pure latency on a cold open, during which the CPU is idle and the network is idle between hops.

The §1.3 disk-first check removes that chain entirely on a *warm* process — which is the common case and the biggest single win in this document. But on a genuinely cold open the vault is now **latency-bound, not CPU- or bandwidth-bound**, and the one remaining lever is collapsing the chain: a single RPC returning metadata *and* the first 24 signed URLs in one response, fired on screen mount rather than after the query. Until that exists, a cold open will feel like about a second of a correctly laid-out grid with no pictures in it, and no amount of cache tuning changes that number.