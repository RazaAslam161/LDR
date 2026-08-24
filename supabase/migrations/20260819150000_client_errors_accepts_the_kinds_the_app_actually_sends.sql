-- Recovered from the production ledger on 2026-08-23; never committed.
--
-- Applied to prod `sopictusdonlvuezmfep` as version 20260819170255 on
-- 2026-08-19 17:02 UTC, then lost with the disk that held the working
-- tree. The body below is byte-identical to that ledger's stored
-- statements, md5 verified. The explanatory comment this repo's style
-- asks for is absent because it was never in the ledger: these were
-- applied as bare SQL, so whatever prose sat above them died with the
-- disk.
--
-- Renumbered to 20260819150000 so replay order stays correct against the
-- slot scheme the other files in this directory use.

alter table public.client_errors drop constraint if exists client_errors_kind_check;

alter table public.client_errors add constraint client_errors_kind_check
  check (kind ~ '^[a-z][a-z0-9_-]{0,39}$');

comment on column public.client_errors.kind is
  'Which call site reported. A short machine slug written by the code, never '
  'assembled from a value: it is the grouping key the reporter also dedups on. '
  'Was restricted to flutter/platform until 20260819220100, which silently '
  'rejected every other reporter in the app.';
