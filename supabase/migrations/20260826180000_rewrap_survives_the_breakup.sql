-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the rewrap ceremony survives the breakup.
--
-- THE SHARPEST RISK IN THE WHOLE SEVERANCE PLAN, and it is a cryptographic one.
--
-- A device's X25519 identity changes on a reinstall, a keystore wipe or a new
-- phone. When it does, the couple key derived from it changes too, and every
-- byte written under the old one stops opening. The ONLY thing that carries a
-- key chain across that gap without handing the operator a second door is
-- PartnerRewrap: the reinstalling phone posts a fresh public key plus an
-- Argon2id commitment to six digits, the partner hears the digits on a call,
-- types them, and seals the whole chain to the new key.
--
-- That ceremony cannot run while unpaired. `partner_rewrap_requests.couple_id`
-- is NOT NULL and three of its four policies test
-- `couple_id = current_user_couple_id()`, which is null for an unpaired
-- account. Verified against production before writing this:
--
--   partner_rewrap_member  SELECT  couple_id = (select current_user_couple_id())
--   partner_rewrap_open    INSERT  couple_id = … AND from_user = auth.uid()
--   partner_rewrap_answer  UPDATE  couple_id = … AND from_user <> auth.uid()
--                                    AND wrapped_keys is null AND expires_at > now()
--   partner_rewrap_close   DELETE  from_user = auth.uid()   ← couple-independent
--
-- So the only recovery left to somebody who reinstalls during the 30-day window
-- is KeyEscrow, i.e. their account password. Forget it, or reset it, and the
-- shared history is cryptographically dead even after the couple is restored.
-- key_escrow.dart says so in its own words: "a forgotten password means the
-- escrow cannot be opened either."
--
-- A reinstall during a broken window is not an edge case. It is what people do
-- after a fight. Stage 6 gives that window a way back; this is what stops the
-- way back leading to unreadable rows.
--
-- WHY THREE POLICIES AND NOT FOUR. partner_rewrap_close already resolves on
-- `from_user = auth.uid()` alone and works unpaired as it stands. Adding a
-- fourth would widen nothing and imply a boundary that is not there.
--
-- UPDATE NEEDS NO GRANT CHANGE. `authenticated` holds no table-level UPDATE on
-- this table — only column grants on wrapped_at, wrapped_by and wrapped_keys,
-- which is the answer step and nothing else. The new policy ORs alongside the
-- existing one; what may be written is still fixed by those three columns.
-- ───────────────────────────────────────────────────────────────────────────

-- ── The ceremony, reachable inside the window ──────────────────────────────
-- All three are PERMISSIVE and sit BESIDE the live-couple policies, which are
-- not touched by a single character. Postgres ORs permissive policies of the
-- same command, so a paired user's path is exactly what it was.
--
-- Every one routes through current_user_restorable_couple_id(), which is where
-- the safety argument lives: it resolves only for a non-severed member of a
-- couple dissolved inside the window who is not currently paired with anybody
-- else. Nothing here can widen a live couple's boundary or reach a stranger's.

drop policy if exists partner_rewrap_member_restorable on public.partner_rewrap_requests;
create policy partner_rewrap_member_restorable on public.partner_rewrap_requests
  for select using (
    couple_id = (select public.current_user_restorable_couple_id()));

drop policy if exists partner_rewrap_open_restorable on public.partner_rewrap_requests;
create policy partner_rewrap_open_restorable on public.partner_rewrap_requests
  for insert with check (
    couple_id = (select public.current_user_restorable_couple_id())
    and from_user = (select auth.uid()));

-- Mirrors partner_rewrap_answer exactly, restorable couple in place of live:
-- you may only answer somebody ELSE's request, only while it is unanswered and
-- unexpired, and the row must record YOU as the one who sealed it.
drop policy if exists partner_rewrap_answer_restorable on public.partner_rewrap_requests;
create policy partner_rewrap_answer_restorable on public.partner_rewrap_requests
  for update using (
    couple_id = (select public.current_user_restorable_couple_id())
    and from_user <> (select auth.uid())
    and wrapped_keys is null
    and expires_at > now())
  with check (
    couple_id = (select public.current_user_restorable_couple_id())
    and from_user <> (select auth.uid())
    and wrapped_by = (select auth.uid()));

-- ── The one row that completes it ──────────────────────────────────────────
-- PartnerRewrap.claim() reads the OTHER person's partner_keys row to unseal
-- what they sealed. partner_keys_select_member scopes that to the live couple,
-- so without this the ceremony can be opened and answered inside the window and
-- still not finish.
--
-- DELIBERATELY NOT AN AMBIENT READ. partner_keys.updated_at is a rotation
-- timeline, and "my ex just reinstalled their phone" is a behavioural signal
-- about somebody who left. This exposes exactly one row, for at most as long as
-- the request lives, and ONLY after that person affirmatively answered —
-- wrapped_by is null until they do. The key becomes readable because they chose
-- to hand it over, which is the same consent the rest of this design rests on.
drop policy if exists partner_keys_select_rewrap_peer on public.partner_keys;
create policy partner_keys_select_rewrap_peer on public.partner_keys
  for select using (
    exists (
      select 1 from public.partner_rewrap_requests r
       where r.couple_id  = (select public.current_user_restorable_couple_id())
         and r.from_user  = (select auth.uid())
         and r.wrapped_by = public.partner_keys.user_id
         and r.expires_at > now()));

-- ── Assertions ─────────────────────────────────────────────────────────────
-- 1. The live-couple policies still stand. Every new policy above is permissive
--    and additive; if a later edit ever REPLACES one of the originals instead
--    of sitting beside it, that argument silently stops holding.
do $do$
declare v_missing text;
begin
  select string_agg(want, ', ') into v_missing
    from (values ('partner_rewrap_member'),('partner_rewrap_open'),
                 ('partner_rewrap_answer'),('partner_rewrap_close')) as t(want)
   where not exists (
     select 1 from pg_policies
      where schemaname='public' and tablename='partner_rewrap_requests'
        and policyname = t.want);
  if v_missing is not null then
    raise exception
      'the original rewrap policies are gone (%) — the restorable ones were '
      'meant to sit BESIDE them, not replace them; a paired couple would lose '
      'the ceremony entirely', v_missing;
  end if;
end $do$;

-- 2. UPDATE stays column-scoped. A table-level grant here would let the answer
--    step rewrite couple_id, from_user, new_public_key or code_hash — i.e. let
--    somebody answer a request by first editing whose request it is.
do $do$
declare v_extra text;
begin
  if has_table_privilege('authenticated','public.partner_rewrap_requests','UPDATE') then
    -- has_table_privilege reports true when ANY column is grantable, so compare
    -- the actual column set rather than trusting the table-level answer.
    select string_agg(column_name, ', ' order by column_name) into v_extra
      from information_schema.role_column_grants
     where table_schema='public' and table_name='partner_rewrap_requests'
       and grantee='authenticated' and privilege_type='UPDATE'
       and column_name not in ('wrapped_at','wrapped_by','wrapped_keys');
    if v_extra is not null then
      raise exception
        'authenticated may UPDATE %(s) on partner_rewrap_requests — the answer '
        'step must be able to write wrapped_at, wrapped_by and wrapped_keys and '
        'nothing else', v_extra;
    end if;
  end if;
end $do$;

-- 3. The peer key read is gated on an ANSWERED request. If wrapped_by ever
--    stops appearing in that predicate, the policy degrades into "any ex can
--    read the other's key row for as long as a request is open", which hands
--    over a rotation timeline nobody consented to.
do $do$
declare v_qual text;
begin
  select qual into v_qual from pg_policies
   where schemaname='public' and tablename='partner_keys'
     and policyname='partner_keys_select_rewrap_peer';
  if v_qual is null then
    raise exception 'partner_keys_select_rewrap_peer did not get created';
  end if;
  if position('wrapped_by' in v_qual) = 0
  or position('expires_at' in v_qual) = 0 then
    raise exception
      'partner_keys_select_rewrap_peer no longer requires an answered, '
      'unexpired request (qual: %) — it must expose the peer key only after '
      'they chose to hand it over', v_qual;
  end if;
end $do$;

-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   drop policy if exists partner_keys_select_rewrap_peer     on public.partner_keys;
--   drop policy if exists partner_rewrap_answer_restorable    on public.partner_rewrap_requests;
--   drop policy if exists partner_rewrap_open_restorable      on public.partner_rewrap_requests;
--   drop policy if exists partner_rewrap_member_restorable    on public.partner_rewrap_requests;
--
-- Strictly reversible: no data written, no column added, no existing policy or
-- grant touched. Note what the rollback restores, so it is chosen knowingly —
-- a reinstall inside the window goes back to having no recovery but the account
-- password, and a forgotten password there means the history is gone.
--
-- Second run: no-op. Every policy is dropped-if-exists then created; the three
-- assertion blocks are read-only.
--
-- CLIENT HALF, DEFERRED ON PURPOSE. PartnerRewrap.pending() takes a couple id
-- and the session has none while unpaired, so it must read
-- couple_restore_state() instead. That is left for stage 6's client work rather
-- than done here: the screen that would reach this state does not exist yet,
-- and shipping the plumbing early would put a control on screen that cannot do
-- anything. The database side is ready and inert until something calls it.
