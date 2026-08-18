-- §63 follow-up: a consent gate a partner can flip for you is not a consent
-- gate. consent_state's write policies were minted by 20260601001400's
-- generic couple-scope loop, so either member could INSERT/UPDATE/DELETE the
-- OTHER member's consent row. dice_tier_consents — the same shape — was
-- user-scoped in the 2026-08-17 audit close; consent_state was missed.
--
-- SELECT stays couple-wide on purpose: computing "both partners consented"
-- requires reading the partner's row. Writes now require the row to be YOURS.
--
-- No client writes this table at all today (repo-wide grep 2026-08-18:
-- migrations and docs only), so nothing can break; this closes the door
-- before a feature opens it.
--
-- Second run: no-op (drop if exists + create).
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   Re-run 20260601001400's generic loop body for consent_state only, i.e.
--   recreate the three policies with the bare couple check:
--     with check (couple_id = (select public.current_user_couple_id()))
--   (and the same predicate as USING on update/delete).
-- ───────────────────────────────────────────────────────────────────────────

drop policy if exists "consent_state_insert_member" on public.consent_state;
create policy "consent_state_insert_member" on public.consent_state
  for insert with check (
    couple_id = (select public.current_user_couple_id())
    and user_id = (select auth.uid())
  );

drop policy if exists "consent_state_update_member" on public.consent_state;
create policy "consent_state_update_member" on public.consent_state
  for update using (
    couple_id = (select public.current_user_couple_id())
    and user_id = (select auth.uid())
  ) with check (
    couple_id = (select public.current_user_couple_id())
    and user_id = (select auth.uid())
  );

drop policy if exists "consent_state_delete_member" on public.consent_state;
create policy "consent_state_delete_member" on public.consent_state
  for delete using (
    couple_id = (select public.current_user_couple_id())
    and user_id = (select auth.uid())
  );
