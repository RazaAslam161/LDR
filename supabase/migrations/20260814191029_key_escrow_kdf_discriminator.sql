-- Applied to production on 2026-08-14 and never written down. Reconstructed
-- here from supabase_migrations.schema_migrations under the version it was
-- recorded at, so a fresh environment replayed from this directory ends up with
-- the same key_escrow as production instead of one the client writes columns
-- that do not exist on. Idempotent: production already has both columns and
-- re-running this must not touch a single sealed row.
--
-- The wrapping key was derived with HKDF-SHA256 over the raw password: roughly
-- two HMAC operations per guess, so a dump of this table falls to offline
-- cracking of any human-chosen password. That is exactly the threat end-to-end
-- encryption exists to survive.
--
-- Record which KDF sealed each row so the client can dispatch on read and
-- re-wrap legacy rows in place. Defaulting to 'hkdf-sha256' correctly labels
-- every row written before this change. Deployed ahead of the APK so existing
-- clients, which do not write these columns, keep working unchanged.

alter table public.key_escrow
  add column if not exists kdf text not null default 'hkdf-sha256',
  add column if not exists kdf_params jsonb not null default '{}'::jsonb;

