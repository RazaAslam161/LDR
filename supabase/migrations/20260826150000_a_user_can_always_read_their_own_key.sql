-- ───────────────────────────────────────────────────────────────────────────
-- Miles — a user can always read their own public key.
--
-- THE BUG. `partner_keys_select_member` (20260601001000:17-23) scopes reads to
-- the caller's couple:
--
--   user_id in (select p.id from profiles p
--                where p.couple_id = (select current_user_couple_id()))
--
-- Unpaired, current_user_couple_id() is null, `p.couple_id = null` is never
-- true, the subquery is empty — and the caller cannot read their OWN row. RLS
-- filters rather than errors, so `.maybeSingle()` answers null without
-- throwing, and the miss is indistinguishable from "no row exists".
--
-- THE POLICY SET IS ALREADY INCONSISTENT ABOUT THIS, which is the tell that
-- this is an oversight and not a boundary. Verified against production:
--   partner_keys_insert_self  INSERT  with_check user_id = (select auth.uid())
--   partner_keys_update_self  UPDATE  using/check user_id = (select auth.uid())
--   partner_keys_select_member SELECT couple-scoped  ← the odd one out
-- An unpaired account may already WRITE its own row and may already REPLACE
-- it. It just cannot read back what it wrote. Nothing is being opened here
-- that was closed; the read is being brought into line with the writes.
--
-- WHAT IT COSTS TODAY. Two call sites read the caller's own row and both
-- silently mis-answer while unpaired:
--
--   publishMyPublicKey (supabase_repository.dart:466-474) selects `existing`
--   to compare against the key it is about to publish. Unpaired that select
--   returns null, so `prev` is null, so `keyWasReplaced` is never set — the
--   app does not tell the user that the history it just derived a new identity
--   for has become unreadable. It stays quiet about destroying it.
--
--   _publishedIdentity (supabase_repository.dart:236-250) returns false for
--   both "never published" and "unpaired, so hidden". Its own doc comment
--   concedes this and argues it is survivable "only because of what an
--   unpaired account is: it has no partner, so the ceremony false would skip
--   has nobody to answer it."
--
-- THAT ARGUMENT IS ABOUT TO BE FALSE. The severance work gives a dissolved
-- couple a way back, so an unpaired account DOES still have a partner who
-- could answer the ceremony — and the rewrap ceremony is what carries a key
-- chain across a reinstall. A person who reinstalls during the broken window
-- (exactly what people do after a fight) is the case this silence strands. So
-- the read has to be authoritative before anything depends on it.
--
-- HOW. A second PERMISSIVE policy for the same command. Postgres ORs
-- permissive policies, so `partner_keys_select_member` is left untouched — not
-- one character — and the live-couple predicate is not weakened. The shape is
-- copied verbatim from key_escrow_own_select in this same database, which has
-- always had it right:
--   key_escrow_own_select  SELECT  using (user_id = (select auth.uid()))
--
-- WHAT THIS DOES NOT DO. It grants exactly one row: the caller's own. It does
-- not let an ex read a former partner's key, and it does not let anyone read a
-- stranger's. partner_keys.updated_at is a rotation timeline — "my ex just
-- reinstalled their phone" is a behavioural signal about someone who left —
-- and reading another person's row stays couple-scoped, as it was.
-- ───────────────────────────────────────────────────────────────────────────

drop policy if exists partner_keys_select_own on public.partner_keys;
create policy partner_keys_select_own on public.partner_keys
  for select using (user_id = (select auth.uid()));

-- The subselect wrapper is not cosmetic. 20260601004200 rewrote every policy in
-- the schema to hoist auth.uid() into an InitPlan so it is evaluated once per
-- statement rather than once per row; a bare auth.uid() here would be the only
-- un-hoisted predicate left on this table and would quietly reintroduce the
-- per-row call that migration exists to remove.

-- ── Assertion: the couple-scoped policy is still standing, unmodified ──────
-- The whole safety argument for this change is that it ADDS a permissive
-- policy beside the existing one. If a later edit ever replaces the member
-- policy instead of sitting beside it, that argument silently stops holding.
do $do$
declare v_member text;
begin
  select qual into v_member
    from pg_policies
   where schemaname='public' and tablename='partner_keys'
     and policyname='partner_keys_select_member';
  if v_member is null then
    raise exception
      'partner_keys_select_member is gone — partner_keys_select_own was meant '
      'to sit BESIDE it, not replace it. A self-only read policy on its own '
      'stops a paired user reading their partner''s key, which breaks every '
      'derive door in the app.';
  end if;
  if position('current_user_couple_id' in v_member) = 0 then
    raise exception
      'partner_keys_select_member no longer resolves against the caller''s '
      'couple (qual is now: %) — re-check that partner key reads are still '
      'scoped before relying on this migration''s reasoning', v_member;
  end if;
end $do$;

-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   drop policy if exists partner_keys_select_own on public.partner_keys;
-- Strictly reversible. No data is written, no column added, no existing policy
-- touched, and dropping it restores the previous read boundary exactly.
--
-- Note what the rollback costs, so the decision is made knowingly: it puts the
-- silence back. keyWasReplaced stops firing for unpaired accounts and
-- _publishedIdentity goes back to conflating "never published" with "hidden".
--
-- Second run: no-op. The policy is dropped-if-exists then recreated, and the
-- assertion block is read-only.
