-- The Shared Vault could never have worked.
--
-- It encrypts media on-device and uploads an opaque ciphertext blob as
-- application/octet-stream. couple_intimate's allowed_mime_types listed only
-- plaintext image/video/audio types, so Storage answered EVERY vault media
-- upload with 415 invalid_mime_type. The client showed a spinner because the
-- rejection surfaced as a failed future the screen never rendered.
--
-- Adding the type rather than clearing the whitelist: the whitelist is what
-- stops a plaintext photograph being written into the encrypted vault by some
-- future bug, and that is worth keeping.
update storage.buckets
   set allowed_mime_types = allowed_mime_types || array['application/octet-stream']
 where id = 'couple_intimate'
   and not ('application/octet-stream' = any(allowed_mime_types));

-- Afterglow allowed several unsealed entries per couple, and production had
-- two for one couple, both holding partner A's half. fetchPending returns one
-- of them, the form saw "I already contributed", and threw — permanently, with
-- no way to view, edit or clear it. The client now replaces its own half
-- instead of throwing; this stops the duplicates that made it reachable.
create unique index if not exists afterglow_one_pending_per_couple
  on public.afterglow_entries (couple_id)
  where sealed_at is null;
