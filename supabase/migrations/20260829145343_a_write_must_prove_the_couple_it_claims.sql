-- A write must prove the couple it claims.
--
-- Three places where a write path names a couple — or a parent row that
-- belongs to one — and nothing on the server checks that the caller is in it.
-- All three are least-privilege gaps, not open doors: none is reachable from
-- any shipped screen, and none leaks the other side's data. What they leak is
-- the ability to leave a row somewhere it does not belong, in a couple the
-- author is not part of, that the couple cannot delete.
--
-- 1. redeem_pairing_invite() lost its already_paired guard somewhere between
--    20260601000900 (which had it, :80) and 20260818180000 (the live
--    definition). Between the same-couple early return and
--    `update profiles set couple_id = ...` there is only a dissolved check and
--    a capacity check on the TARGET couple — nothing asks whether the CALLER's
--    couple still has a partner standing in it. It is not an escape from the
--    unlink ceremony: leave_couple() and leave_couple_permanently() are both
--    granted to `authenticated` and end a couple in one call by design
--    (20260826170000), so a raw caller never needed redeem to get out. What
--    the bare update does that leaving does not is skip every piece of
--    leave_couple's cleanup: couples.dissolved_at stays null so the restore
--    handshake (20260826190000) has nothing to key on, the abandoned partner's
--    profiles.couple_id still points at a couple with one member in it,
--    presence survives on both rows — coordinates, location label, body photo,
--    mood, all of which leave_couple nulls and queues for reaping
--    (20260826140000) — the couple's other live invites are never consumed,
--    and an open couple_unlink row outlives the couple's last member because
--    its dies-with-couple trigger never fires, so the initiator's next
--    unlink_execute() raises no_active_couple forever. couple_members is NOT
--    part of the damage: the profiles sync trigger (20260826160000) fires on
--    the bare update and closes the old membership correctly.
--
--    The guard restores the error string every shipped client already maps
--    (supabase_repository.dart:634), so builds 49-64 render it as the message
--    they were written for rather than a raw Postgres error.
--
-- 2. routine_checks and shared_reel_views scope their writes by owner alone.
--    Their SELECT policies resolve the couple through the PARENT row
--    (routine_items / shared_reels), which makes the parent the isolation
--    boundary on read — but item_id and reel_id are unchecked on write, and
--    both tables are granted full DML with no column list. A tick written
--    against a stranger's routine item lands inside that couple's read scope,
--    and neither of them can remove it: their own delete and update policies
--    are user_id = auth.uid() too. routine_checks also grants UPDATE, so an
--    existing legitimate row can be re-pointed onto a foreign item with no
--    insert at all. Every sibling policy in 20260815071213 already pairs the
--    owner term with the couple — gallery_insert_member, shared_reels_insert,
--    watch_sessions_write — so this is a slip, not a convention.
--
-- 3. cycle_events, cycle_logs and cycle_settings take couple_id off the wire
--    and never validate it. No trigger covers them (guard_couple_id is
--    `before update of couple_id on profiles` only), so any authenticated
--    identity can persist rows tagged with an arbitrary couple that the tagged
--    couple can read over REST and cannot delete. It renders nowhere — every
--    client read filters on user_id, never couple_id — so nobody's calendar
--    shows a stranger's period. The real shapes are row injection into another
--    couple's storage, and a departed member still tagging rows at the couple
--    they left.
--
-- WHAT THIS FILE DOES NOT DO: it does not tighten any USING clause. A row a
-- member wrote before an unlink stays theirs to update and delete after it;
-- only the row that RESULTS from the write has to name a couple the writer is
-- in. And couple_id stays nullable on cycle_events / cycle_settings, so the
-- added term tolerates NULL — a row that claims no couple harms no couple, and
-- making null-couple rows unwritable would strand every row written before the
-- column was populated. cycle_logs.couple_id is NOT NULL, so its term is the
-- strict one.
--
-- Second run: no-op. The function is CREATE OR REPLACE, every policy is
-- DROP IF EXISTS by its exact live name before CREATE, and the assertions at
-- the bottom are read-only.
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
-- Re-apply 20260818180000 in full (it is CREATE OR REPLACE and contains the
-- unguarded redeem), then restore the three child-row policies to their
-- owner-only form:
--
--   drop policy if exists routine_checks_own_insert on public.routine_checks;
--   create policy routine_checks_own_insert on public.routine_checks
--     for insert with check (user_id = (select auth.uid()));
--   drop policy if exists routine_checks_own_update on public.routine_checks;
--   create policy routine_checks_own_update on public.routine_checks
--     for update using (user_id = (select auth.uid()))
--             with check (user_id = (select auth.uid()));
--   drop policy if exists shared_reel_views_own on public.shared_reel_views;
--   create policy shared_reel_views_own on public.shared_reel_views
--     for insert with check (user_id = (select auth.uid()));
--
-- and the six cycle write policies (cycle_events_insert, cycle_events_update,
-- cycle_logs_insert, cycle_logs_update, cycle_settings_insert,
-- cycle_settings_update) to the owner-only pair in 20260815071213:96-100 and
-- its cycle_logs / cycle_settings twins. Rolling back leaves any row already
-- written under the tighter policies exactly where it is; nothing here
-- migrates data.
--
-- Re-applying 20260818180000 also restores the six-table burner sweep, which
-- is what couple_has_content replaces. Drop the helper last, after nothing
-- calls it:
--
--   drop function if exists public.couple_has_content(uuid);
-- ───────────────────────────────────────────────────────────────────────────

-- ── 0. "Is this couple really empty?", asked of the catalogue ──────────────
-- The burner sweep inside redeem_pairing_invite hand-listed six tables. There
-- are 44 with a couple_id column, so a solo user in a couple of one — the very
-- case the sweep exists for, both partners having minted a code — could leave
-- behind cycle_events, cycle_settings, routine_items, shared_reels, rituals,
-- gallery_items and the rest, and `delete from couples` would cascade them all
-- away without one of them ever being counted.
--
-- Hand-listing 44 has the same defect one line later: the 45th table reopens
-- the hole silently, and nothing fails when someone forgets. So the question is
-- asked of pg_attribute instead, and the default is DENY — an unrecognised
-- couple-scoped table counts as content, which at worst leaves an empty couple
-- standing for prune_dissolved_couples to take. Leaving a row behind is
-- recoverable; deleting one that mattered is not.
--
-- The four exclusions are bookkeeping ABOUT the couple rather than content
-- inside it, and every one of them is non-empty at exactly this moment:
-- pairing_invites holds the code just consumed, profiles is what the caller
-- moved off, couple_members is the pairing ledger, diag_events is telemetry.
create or replace function public.couple_has_content(p_couple uuid)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $fn$
declare
  r        record;
  v_found  boolean;
begin
  if p_couple is null then return false; end if;
  for r in
    select c.relname
      from pg_attribute a
      join pg_class     c on c.oid = a.attrelid
      join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public'
       and c.relkind = 'r'
       and a.attname = 'couple_id'
       and a.attnum  > 0
       and not a.attisdropped
       and c.relname not in ('pairing_invites','profiles',
                             'couple_members','diag_events')
  loop
    execute format('select exists (select 1 from public.%I where couple_id = $1)',
                   r.relname)
       into v_found
      using p_couple;
    if v_found then return true; end if;
  end loop;
  return false;
end $fn$;

revoke execute on function public.couple_has_content(uuid) from public, anon, authenticated;

-- ── 1. redeem_pairing_invite: the already_paired guard, restored ───────────
-- Byte-identical to 20260818180000 apart from the guard block. The
-- same-couple early return above it is what the client leans on when a
-- partner re-enters a code they already redeemed, so the guard sits BELOW it:
-- re-redeeming your own couple's code stays idempotent.

create or replace function public.redeem_pairing_invite(p_code text)
returns couples language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  -- I->1 and O->0 because the generator never emits I or O, so a user who
  -- typed one meant the digit. A no-op for the hex codes minted before this,
  -- which contain neither.
  v_clean text := translate(
    upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g')), 'IO', '10');
  v_invite public.pairing_invites;
  v_couple public.couples;
  v_my_couple uuid;
  v_count int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  -- There is deliberately no failed-attempt limiter here; see 20260818130000.
  -- A counter in this transaction dies with the raise that reports the
  -- failure, and production proved it: 0 failure rows after months. Do not
  -- re-add one without first solving that rollback.

  select couple_id into v_my_couple from public.profiles where id = v_uid;
  select * into v_invite from public.pairing_invites where code = v_clean;

  if not found or v_invite.consumed_at is not null or v_invite.expires_at < now() then
    raise exception 'invalid_code';
  end if;

  if v_my_couple = v_invite.couple_id then
    insert into public.pairing_attempts (user_id, ok) values (v_uid, true);
    select * into v_couple from public.couples where id = v_invite.couple_id;
    return v_couple;
  end if;

  -- Leaving is one RPC away and always has been; this is not about stopping
  -- an exit. It is about the update below being the ONLY way a member walks
  -- off a couple that still has somebody in it WITHOUT leave_couple's
  -- cleanup — undissolved couple, partner pointed at a ghost, presence and
  -- coordinates left standing, a couple_unlink row that now outlives its
  -- couple. A solo caller keeps redeeming: the empty-couple sweep further
  -- down deletes the burner couple they came from.
  if v_my_couple is not null
     and exists (select 1 from public.profiles
                  where couple_id = v_my_couple and id <> v_uid)
  then
    raise exception 'already_paired';
  end if;

  -- The second belt to leave_couple's braces: a code minted before that
  -- migration is still live in the table and still points at a dead couple.
  if exists (select 1 from public.couples
              where id = v_invite.couple_id and dissolved_at is not null) then
    raise exception 'couple_dissolved';
  end if;

  select count(*) into v_count from public.profiles where couple_id = v_invite.couple_id;
  if v_count >= 2 then
    raise exception 'couple_full';
  end if;

  update public.profiles set couple_id = v_invite.couple_id where id = v_uid;
  update public.pairing_invites set consumed_at = now(), consumed_by = v_uid
   where code = v_clean;
  insert into public.pairing_attempts (user_id, ok) values (v_uid, true);

  -- The six-table hand-list this replaces is in 20260818180000:171-180. See
  -- couple_has_content above for why the question is asked of the catalogue.
  if v_my_couple is not null
     and not exists (select 1 from public.profiles where couple_id = v_my_couple)
     and not public.couple_has_content(v_my_couple)
  then
    delete from public.couples where id = v_my_couple;
  end if;

  select * into v_couple from public.couples where id = v_invite.couple_id;
  return v_couple;
end $fn$;

-- ── 2. Child rows answer to their parent's couple ──────────────────────────
-- Same subquery shape the SELECT policies already use, so a tick or a view
-- can only be written against a parent the caller can read. USING stays
-- owner-only: a member who leaves keeps the right to clear their own rows.

drop policy if exists routine_checks_own_insert on public.routine_checks;
create policy routine_checks_own_insert on public.routine_checks
  for insert with check (user_id = (select auth.uid())
                         and item_id in (
                           select id from public.routine_items
                            where couple_id = (select public.current_user_couple_id())));
drop policy if exists routine_checks_own_update on public.routine_checks;
create policy routine_checks_own_update on public.routine_checks
  for update using (user_id = (select auth.uid()))
          with check (user_id = (select auth.uid())
                      and item_id in (
                        select id from public.routine_items
                         where couple_id = (select public.current_user_couple_id())));

drop policy if exists shared_reel_views_own on public.shared_reel_views;
create policy shared_reel_views_own on public.shared_reel_views
  for insert with check (user_id = (select auth.uid())
                         and reel_id in (
                           select id from public.shared_reels
                            where couple_id = (select public.current_user_couple_id())));

-- ── 3. cycle_*: the couple_id you write is the couple you are in ───────────
-- Null tolerated on events and settings only because the column is nullable
-- there; cycle_logs.couple_id is NOT NULL and gets the strict term. The read
-- policies are untouched — cycle_settings_read in particular carries the
-- share_with_partner consent added by 20260817160000 and must not be reverted
-- by being re-created here.

drop policy if exists cycle_events_insert on public.cycle_events;
create policy cycle_events_insert on public.cycle_events
  for insert with check (user_id = (select auth.uid())
                         and (couple_id is null
                              or couple_id = (select public.current_user_couple_id())));
drop policy if exists cycle_events_update on public.cycle_events;
create policy cycle_events_update on public.cycle_events
  for update using (user_id = (select auth.uid()))
          with check (user_id = (select auth.uid())
                      and (couple_id is null
                           or couple_id = (select public.current_user_couple_id())));

drop policy if exists cycle_logs_insert on public.cycle_logs;
create policy cycle_logs_insert on public.cycle_logs
  for insert with check (user_id = (select auth.uid())
                         and couple_id = (select public.current_user_couple_id()));
drop policy if exists cycle_logs_update on public.cycle_logs;
create policy cycle_logs_update on public.cycle_logs
  for update using (user_id = (select auth.uid()))
          with check (user_id = (select auth.uid())
                      and couple_id = (select public.current_user_couple_id()));

drop policy if exists cycle_settings_insert on public.cycle_settings;
create policy cycle_settings_insert on public.cycle_settings
  for insert with check (user_id = (select auth.uid())
                         and (couple_id is null
                              or couple_id = (select public.current_user_couple_id())));
drop policy if exists cycle_settings_update on public.cycle_settings;
create policy cycle_settings_update on public.cycle_settings
  for update using (user_id = (select auth.uid()))
          with check (user_id = (select auth.uid())
                      and (couple_id is null
                           or couple_id = (select public.current_user_couple_id())));

-- ── Assertions ─────────────────────────────────────────────────────────────
-- Read-only. They exist because every one of these is a WITH CHECK term that
-- a later create-or-replace of the same policy name can silently drop again —
-- which is exactly how findings 2 and 3 survived the 20260815071213 rewrite.

do $$
declare
  v_bad text;
begin
  -- 1. The guard is in the live definition, under the name the shipped
  --    clients map.
  if position('already_paired'
       in pg_get_functiondef('public.redeem_pairing_invite(text)'::regprocedure)) = 0
  then
    raise exception 'redeem_pairing_invite lost its already_paired guard';
  end if;

  -- 2/3. Asked of the TABLE, not of the policy names above: every permissive
  -- policy that can put a row into one of these five must name its boundary
  -- in the WITH CHECK. Written this way because policies are OR'd — one
  -- forgotten owner-only ALL policy left behind by an older migration would
  -- re-open the hole while the nine policies above still read correctly.
  select string_agg(pol.polname::text, ', ' order by pol.polname) into v_bad
    from (values
      ('routine_checks',    'routine_items'),
      ('shared_reel_views', 'shared_reels'),
      ('cycle_events',      'current_user_couple_id'),
      ('cycle_logs',        'current_user_couple_id'),
      ('cycle_settings',    'current_user_couple_id')
    ) as v(tbl, needle)
    join pg_class c on c.relname = v.tbl
    join pg_namespace n on n.oid = c.relnamespace and n.nspname = 'public'
    join pg_policy pol on pol.polrelid = c.oid
   where pol.polpermissive
     and pol.polcmd in ('a', 'w', '*')
     and position(v.needle
           in coalesce(pg_get_expr(pol.polwithcheck, pol.polrelid), '')) = 0;
  if v_bad is not null then
    raise exception 'write policies with no couple boundary: %', v_bad;
  end if;

  -- The consent term 20260817160000 added must still be the read rule; a
  -- careless re-create here would have handed the partner every setting row
  -- again.
  if not exists (
    select 1 from pg_policy p
     where p.polname = 'cycle_settings_read'
       and position('share_with_partner'
             in coalesce(pg_get_expr(p.polqual, p.polrelid), '')) > 0
  ) then
    raise exception 'cycle_settings_read lost its share_with_partner consent';
  end if;
end $$;
