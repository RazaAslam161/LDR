-- The Shared Vault's media path was written against columns that do not exist.
--
-- private_vault_repository.insert() sends storage_path and media_mime_type on
-- every image/video/voice item. Neither column was ever added, so PostgREST
-- answered PGRST204 "could not find the column in the schema cache" and the
-- insert failed AFTER the encrypted blob had already been uploaded — an
-- orphaned object, and a spinner on screen.
--
-- Text notes set neither column, which is why the vault looked half-working
-- rather than broken: notes saved, media never could.
--
-- Second of two server-side blockers. The first was couple_intimate's
-- allowed_mime_types rejecting application/octet-stream with 415, fixed in
-- 20260601006400.
alter table public.vault_items
  add column if not exists storage_path text,
  add column if not exists media_mime_type text;

comment on column public.vault_items.storage_path is
  'Object name in couple_intimate holding the encrypted original. Null for notes and traces, whose ciphertext is inline.';
comment on column public.vault_items.media_mime_type is
  'The PLAINTEXT mime type, so a decrypted file can be handed to the right viewer. The stored object is always application/octet-stream.';
