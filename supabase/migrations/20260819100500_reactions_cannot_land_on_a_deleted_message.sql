-- Recovered from the production ledger on 2026-08-23; never committed.
--
-- Applied to prod `sopictusdonlvuezmfep` as version 20260819043951 on
-- 2026-08-19 04:39 UTC, then lost with the disk that held the working
-- tree. The body below is byte-identical to that ledger's stored
-- statements, md5 verified. The explanatory comment this repo's style
-- asks for is absent because it was never in the ledger: these were
-- applied as bare SQL, so whatever prose sat above them died with the
-- disk.
--
-- Renumbered to 20260819100500 so replay order stays correct against the
-- slot scheme the other files in this directory use.

drop policy if exists message_reactions_insert_own on public.message_reactions;
create policy message_reactions_insert_own on public.message_reactions
  for insert with check (
    user_id = (select auth.uid())
    and couple_id = (select public.current_user_couple_id())
    and exists (
      select 1 from public.messages m
      where m.id = public.message_reactions.message_id
        and m.couple_id = (select public.current_user_couple_id())
        and not m.deleted_for_everyone
    )
  );
