-- Recovered from the production ledger on 2026-08-23; never committed.
--
-- Applied to prod `sopictusdonlvuezmfep` as version 20260819174503 on
-- 2026-08-19 17:45 UTC, then lost with the disk that held the working
-- tree. The body below is byte-identical to that ledger's stored
-- statements, md5 verified. The explanatory comment this repo's style
-- asks for is absent because it was never in the ledger: these were
-- applied as bare SQL, so whatever prose sat above them died with the
-- disk.
--
-- Renumbered to 20260819160000 so replay order stays correct against the
-- slot scheme the other files in this directory use.

create index if not exists messages_couple_edited_idx
  on public.messages (couple_id, edited_at, id)
  where edited_at is not null;

create index if not exists messages_couple_deleted_idx
  on public.messages (couple_id, deleted_at, id)
  where deleted_at is not null;
