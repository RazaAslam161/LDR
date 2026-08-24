-- Recovered from the production ledger on 2026-08-23; never committed.
--
-- Applied to prod `sopictusdonlvuezmfep` as version 20260819040256 on
-- 2026-08-19 04:02 UTC, then lost with the disk that held the working
-- tree. The body below is byte-identical to that ledger's stored
-- statements, md5 verified. The explanatory comment this repo's style
-- asks for is absent because it was never in the ledger: these were
-- applied as bare SQL, so whatever prose sat above them died with the
-- disk.
--
-- Renumbered to 20260819090500 so replay order stays correct against the
-- slot scheme the other files in this directory use.

revoke all on public.message_reactions from anon;
revoke truncate, references, trigger on public.message_reactions
  from authenticated, anon;
grant select, insert, update, delete on public.message_reactions to authenticated;
