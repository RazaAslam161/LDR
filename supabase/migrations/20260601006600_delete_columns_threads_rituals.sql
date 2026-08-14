-- Dual-consent deletion was written for both features and never migrated.
--
-- memory_thread_repository.requestDeletion / cancelDeletion / hardDelete write
-- delete_requested_by, delete_requested_at, deleted_by and deleted_at. None
-- existed, so every delete threw PGRST204. That is the whole of "memory threads
-- have no delete option" — the action existed and could never succeed.
--
-- rituals was worse: ritual_repository.fetch filters .neq('deleted', true) on a
-- column that did not exist, so the LIST QUERY failed. Not just deletion — the
-- entire rituals feature.
--
-- Third instance of the same fault in one session, after the vault's
-- storage_path/media_mime_type and afterglow's missing constraint: client code
-- shipped against a schema that was never applied. Worth a hygiene test that
-- diffs every column name the repositories write against information_schema.
alter table public.memory_threads
  add column if not exists delete_requested_by  uuid references auth.users(id),
  add column if not exists delete_requested_at  timestamptz,
  add column if not exists deleted_by           uuid references auth.users(id),
  add column if not exists deleted_at           timestamptz;

alter table public.rituals
  add column if not exists deleted              boolean not null default false,
  add column if not exists delete_requested     boolean not null default false,
  add column if not exists delete_requested_by  uuid references auth.users(id),
  add column if not exists delete_requested_at  timestamptz,
  add column if not exists deleted_by           uuid references auth.users(id),
  add column if not exists deleted_at           timestamptz;

create index if not exists rituals_live_idx
  on public.rituals (couple_id) where deleted = false;

create index if not exists memory_threads_live_idx
  on public.memory_threads (couple_id, state);
