-- The personal vault stored a STRING, not media: either a public URL or
-- 'intimate:<path>' pointing into the couple's SHARED bucket. Three
-- consequences, all of which this migration exists to end:
--
--   1. No privacy. intimate_select gates on
--      foldername(name)[1] = current_user_couple_id(), and both partners share
--      that id — so the partner could read the identical bytes of anything
--      "saved to my private vault". Only the LIST was private.
--   2. No durability. intimate_delete has the same predicate, so the partner
--      could destroy a vault item.
--   3. No permanence. Photos and voice notes were saved as an already-expiring
--      24h signed URL, so they died within a day by construction. That is the
--      "Link expired" toast, and it was not an edge case.
--
-- The vault now owns its bytes, in its own bucket, keyed on the OWNER.
--
-- Already applied to production on 2026-08-16; this file exists so the repo can
-- reproduce its own schema. Re-running is a no-op: the bucket upserts and every
-- policy and column is guarded.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'personal_vault', 'personal_vault', false, 104857600,
  -- application/octet-stream is required, not optional: vault objects are
  -- ciphertext, and an opaque blob uploaded under its original mime is rejected
  -- with 415 invalid_mime_type. That exact omission broke the intimate bucket
  -- once already.
  array['application/octet-stream','image/jpeg','image/png','image/webp',
        'video/mp4','video/quicktime','audio/mpeg','audio/mp4','audio/aac']
)
on conflict (id) do update
  set file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Granted to `authenticated`, and compared against auth.uid() — deliberately
-- not the shape couple_intimate uses, which is granted to `public` and only
-- fails closed by accident (current_user_couple_id() returns NULL for an anon
-- caller, so the comparison is NULL rather than true).
drop policy if exists "personal_vault_select_own" on storage.objects;
create policy "personal_vault_select_own" on storage.objects
  for select to authenticated
  using (bucket_id = 'personal_vault'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "personal_vault_insert_own" on storage.objects;
create policy "personal_vault_insert_own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'personal_vault'
              and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "personal_vault_update_own" on storage.objects;
create policy "personal_vault_update_own" on storage.objects
  for update to authenticated
  using (bucket_id = 'personal_vault'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

drop policy if exists "personal_vault_delete_own" on storage.objects;
create policy "personal_vault_delete_own" on storage.objects
  for delete to authenticated
  using (bucket_id = 'personal_vault'
         and (storage.foldername(name))[1] = (select auth.uid())::text);

-- Additive only. Shipped clients keep writing content/media_url and keep
-- working; new clients write the columns below and ignore the old pair.
--
-- media_nonce/thumb_nonce are reserved and currently UNUSED: packFull() packs
-- the nonce into the blob itself, so the client never writes them. Left in
-- place rather than dropped in a second migration, since dropping a column a
-- shipped client might read is the one shape that cannot be rolled back.
alter table public.personal_vault_items
  add column if not exists storage_path text,
  add column if not exists thumb_path   text,
  add column if not exists mime_type    text,
  add column if not exists media_nonce  bytea,
  add column if not exists thumb_nonce  bytea,
  add column if not exists width        integer,
  add column if not exists height       integer,
  add column if not exists byte_size    bigint;
