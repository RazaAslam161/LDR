-- ───────────────────────────────────────────────────────────────────────────
-- Miles — consent does not outlive the couple.
--
-- TWO HOLES IN 20260829152003, BOTH THE SAME SHAPE: the derivation is right
-- and the LIFECYCLE is not. A `couple_intimacy_consent` row is written when a
-- member says yes and is deleted by nothing at all — not by leave_couple(),
-- not by the ceremony, not by the pruner. It survives the relationship it was
-- given inside.
--
-- 1. CLOSER RE-ARMS ON RESTORE, WITH NOBODY ASKING. leave_couple() nulls both
--    `profiles.couple_id` (20260826140000:107), the sync hook recomputes, and
--    `modest_mode` goes back to true — which looked like the whole story. It
--    is not: both consent rows survive, because their couple still exists for
--    the 30-day window and both profiles still exist, so neither ON DELETE
--    CASCADE fires. Then restore_couple() writes couple_id back onto both rows
--    (20260826190000:221), the hook recomputes, finds two live members and two
--    consents, and writes `modest_mode = false`. Closer is open on both phones
--    the moment the couple comes back, on the strength of a yes given before
--    the breakup. closer_screen.dart's "it stays off until both of you turn it
--    on" is a lie again, one migration after the file that existed to end it.
--
--    Same row, quieter path: A's account is deleted while B keeps the couples
--    row, B later pairs C into it, and B's A-era consent counts as one of the
--    two halves C's Closer needs. C never agreed with the person whose consent
--    is opening their screen.
--
-- 2. A PROFILE DELETED WITH couple_id STILL SET NEVER RECOMPUTES.
--    `profiles_sync_intimacy_modest` was AFTER INSERT OR UPDATE OF couple_id.
--    delete_my_account() happens to null couple_id before it drops the account
--    (20260818150000), so the app's own path was covered by accident — but
--    `delete from auth.users` from the Supabase dashboard or the auth admin
--    API cascades straight into `profiles` with couple_id still set, and
--    nothing recomputes. The consent rows cascade away and the derivation
--    would answer modest, but `couples.modest_mode` is left sitting at false.
--    The survivor's Closer stays open after their partner's account is gone.
--    Builds 49-64 read the column, never the derivation, so for every phone in
--    the field that stale false IS the state — the exact reason 20260829152003
--    made the column derived instead of revoking its grant.
--
-- THE FIX IS A LIFETIME RULE, NOT A CLEANUP STEP. Consent is scoped to a
-- membership, so it ends when the membership ends. The same profiles hook that
-- already recomputes on every couple_id move now also deletes the couple's
-- consent when a member leaves it — by moving couple_id away, or by ceasing to
-- exist. Nothing moves a member out of a couple without going through
-- `profiles.couple_id`; that is precisely the argument 20260826160000 made for
-- hanging membership off this trigger, and it is why no future RPC can forget.
--
-- WHY THE WHOLE COUPLE'S CONSENT AND NOT ONLY THE LEAVER'S. Deleting one row
-- closes Closer today (one consent of two) and leaves the survivor's yes armed
-- for whoever joins that couples row next — case 1's quiet path, still open. A
-- couple that has lost a member is not the couple either of them agreed to.
-- Both rows go; whoever is still there says yes again.
--
-- REJECTED: a composite FK (couple_id, user_id) -> profiles (couple_id, id),
-- which is the shape that would make the stale row literally unrepresentable.
-- Postgres has no ON UPDATE action that DELETES the referencing row: CASCADE
-- would propagate the unlink's NULL into a NOT NULL column and abort, SET NULL
-- the same, and NO ACTION would make leave_couple() fail with a foreign key
-- violation on a fleet that cannot be updated. The referential rule cannot be
-- spelled declaratively, so it is spelled in the one hook every membership
-- move already passes through, and the assertion at the bottom checks the
-- trigger's event mask so a future edit that quietly drops DELETE is caught
-- here rather than by a survivor whose Closer stayed open.
--
-- ADDITIVE. No column, no RPC signature, no payload key, no grant changes.
-- Builds 49-64 keep reading `couples.modest_mode` and keep writing it through
-- the unchanged guard trigger; set_intimacy_consent() and
-- intimacy_consent_state() keep their exact arguments and their exact returned
-- keys ('couple_id','mine','partner','members','modest'). The only difference a
-- client can observe is that after an unlink, a restore, or a partner's account
-- deletion, Closer is closed and both halves read false — which is what the
-- screen's own copy already promises.
--
-- NOT WEAKENED. intimacy_effective_modest(), guard_modest_mode(),
-- recompute_intimacy_modest(), set_intimacy_consent(),
-- intimacy_consent_state(), the couples_modest_mode_two_party trigger and every
-- grant and revoke around them are untouched by this file. Two live members,
-- both consenting, or modest. This file changes only when a consent row stops
-- existing, and the assertion block re-checks the two-party trigger is still
-- there afterwards.
--
-- Second run: no-op. The function is CREATE OR REPLACE, the trigger is DROP IF
-- EXISTS before CREATE, and the one-time sweep's predicate is already false the
-- second time.
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
-- Reinstates 20260829152003's hook exactly. Consent rows this file deleted are
-- not recoverable from anything else, so export first if the rollback is meant
-- to be re-applied:
--
--   create table couple_intimacy_consent_backup as
--     select * from public.couple_intimacy_consent;
--
-- Then re-run, verbatim, the `create or replace function
-- public.sync_intimacy_modest()` body from
-- 20260829152003_closer_opens_only_when_both_of_them_say_so.sql — the version
-- whose only arms are the UPDATE recompute and the `new.couple_id is not null`
-- recompute — followed by:
--
--   drop trigger if exists profiles_sync_intimacy_modest on public.profiles;
--   create trigger profiles_sync_intimacy_modest
--     after insert or update of couple_id on public.profiles
--     for each row execute function public.sync_intimacy_modest();
--
-- The body is cited rather than pasted here on 20260818150000's precedent, and
-- for one extra reason: no migration in this repo has ever put a dollar-quote
-- tag inside a `--` comment, so this file will not be the first to depend on
-- every tool that reads these files being comment-aware before it is
-- dollar-quote-aware.
--
-- Rolling back corrupts nothing — the derivation already ignores consent rows
-- whose owner is not in the couple — it simply restores both defects, and the
-- one that matters is the silent re-arm on restore.
-- ───────────────────────────────────────────────────────────────────────────

-- ── The hook, now covering departure as well as arrival ────────────────────
-- TG_OP tests stay nested rather than ANDed, for 20260826160000's stated
-- reason: PL/pgSQL does not promise to short-circuit a boolean, and `new` is
-- unassigned under DELETE exactly as `old` is under INSERT. The DELETE arm
-- returns early so `new` is never named on that path.
create or replace function public.sync_intimacy_modest()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  -- The profile is going away with its membership still attached: an admin or
  -- auth-API `delete from auth.users`, which cascades here. AFTER ROW, so the
  -- row is already gone from the snapshot the recompute reads and the member
  -- count is right without any arithmetic about it.
  --
  -- The delete below races the user_id -> profiles ON DELETE CASCADE that
  -- would take this member's own row anyway; both orders are correct, because
  -- deleting rows that are already gone matches nothing and raises nothing.
  -- What the cascade cannot do, and why this arm exists, is take the OTHER
  -- member's consent and write the derived column back down.
  if tg_op = 'DELETE' then
    if old.couple_id is not null then
      delete from public.couple_intimacy_consent where couple_id = old.couple_id;
      perform public.recompute_intimacy_modest(old.couple_id);
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    if old.couple_id is not null
       and old.couple_id is distinct from new.couple_id then
      -- Every row of the couple, never just this member's. See the header: one
      -- surviving yes is a yes about somebody who is no longer there, and
      -- restore_couple() re-attaches both profiles to this same couple_id.
      delete from public.couple_intimacy_consent where couple_id = old.couple_id;
      perform public.recompute_intimacy_modest(old.couple_id);
    end if;
  end if;

  if new.couple_id is not null then
    perform public.recompute_intimacy_modest(new.couple_id);
  end if;

  return new;
end $fn$;

revoke execute on function public.sync_intimacy_modest() from public, anon, authenticated;

drop trigger if exists profiles_sync_intimacy_modest on public.profiles;
create trigger profiles_sync_intimacy_modest
  after insert or delete or update of couple_id on public.profiles
  for each row execute function public.sync_intimacy_modest();

comment on table public.couple_intimacy_consent is
  'Per-member consent to the Closer module. couples.modest_mode is DERIVED '
  'from this table and must not be written directly — the BEFORE trigger on '
  'couples turns a direct write into the writer''s own consent. Written only '
  'by set_intimacy_consent() and by that trigger. Scoped to the membership and '
  'deleted with it since 20260829171200: when any member leaves a couple, by '
  'moving couple_id or by having their profile deleted, EVERY consent row of '
  'that couple goes, so a restore or a later re-pairing starts from nobody '
  'having agreed.';

-- ── One-time sweep: consent already left behind ────────────────────────────
-- Production was emptied on 2026-08-29 and 20260829152003 landed after that,
-- so this is zero rows there. It is written for the staging project and for any
-- restore of an older dump, where every unlink since that migration left a pair
-- of rows waiting to re-arm.
--
-- Counts are reported rather than assumed, per 20260829152003's reconciliation:
-- a sweep that silently touches nothing on a database that should have had rows
-- is a finding, not a success — which is why the disagreement is re-asked after
-- the write instead of inferred from the row count.
do $do$
declare v_orphans int; v_rows int; v_left int;
begin
  delete from public.couple_intimacy_consent ic
   where not exists (select 1 from public.profiles p
                      where p.id = ic.user_id
                        and p.couple_id = ic.couple_id);
  get diagnostics v_orphans = row_count;

  -- Deleting consent fires no recompute of its own, so the derived column has
  -- to be walked once by hand. Same GUC bypass as 20260829152003 and for the
  -- same reason: guard_modest_mode() must not read this write as a partner's
  -- opinion and record it as consent. Set local, cleared immediately.
  perform set_config('miles.intimacy_recompute', '1', true);
  update public.couples c
     set modest_mode = public.intimacy_effective_modest(c.id)
   where c.modest_mode is distinct from public.intimacy_effective_modest(c.id);
  get diagnostics v_rows = row_count;
  perform set_config('miles.intimacy_recompute', '', true);

  select count(*) into v_left from public.couples c
   where c.modest_mode is distinct from public.intimacy_effective_modest(c.id);

  raise notice 'consent lifecycle: % stale consent row(s) deleted, % couple '
               'row(s) reconciled, % still disagreeing', v_orphans, v_rows, v_left;
  if v_left > 0 then
    raise exception 'intimacy_effective_modest disagrees with % couple row(s) '
                    'it just wrote — the derivation is not deterministic', v_left;
  end if;
end $do$;

-- ── Assertions ─────────────────────────────────────────────────────────────
-- Read-only.
do $do$
declare v_type int; v_stale int;
begin
  select tgtype into v_type
    from pg_trigger
   where tgrelid = 'public.profiles'::regclass
     and tgname  = 'profiles_sync_intimacy_modest'
     and not tgisinternal;

  if v_type is null then
    raise exception
      'profiles_sync_intimacy_modest is not on profiles — nothing recomputes '
      'couples.modest_mode when a membership moves, so consent outlives the '
      'couple and Closer re-arms on restore';
  end if;

  -- Checked as event bits rather than by reading the function source, because
  -- the way defect 2 comes back is a future migration recreating this trigger
  -- from the old file's text: the body would still handle DELETE and the
  -- trigger would simply never fire on one. tgtype bit 3 (8) is DELETE, bit 4
  -- (16) is UPDATE, bit 2 (4) is INSERT.
  if (v_type & 8) <> 8 then
    raise exception
      'profiles_sync_intimacy_modest no longer fires on DELETE — a profile '
      'deleted with couple_id still set (auth admin API, dashboard) leaves '
      'couples.modest_mode stale at false and the survivor''s Closer open';
  end if;
  if (v_type & 16) <> 16 then
    raise exception
      'profiles_sync_intimacy_modest no longer fires on UPDATE OF couple_id — '
      'unlink and restore stop clearing consent and stop recomputing';
  end if;
  if (v_type & 4) <> 4 then
    raise exception
      'profiles_sync_intimacy_modest no longer fires on INSERT — a couple '
      'formed by pairing never gets its derived modest_mode written';
  end if;

  -- The invariant this file exists to establish, asserted against the data
  -- rather than against the code that maintains it.
  select count(*) into v_stale
    from public.couple_intimacy_consent ic
   where not exists (select 1 from public.profiles p
                      where p.id = ic.user_id
                        and p.couple_id = ic.couple_id);
  if v_stale > 0 then
    raise exception
      '% consent row(s) belong to somebody who is not in that couple — the '
      'sweep above did not hold and Closer can re-arm without either person '
      'asking', v_stale;
  end if;

  -- Fixing the lifecycle must not have loosened the rule it serves.
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.couples'::regclass
       and tgname  = 'couples_modest_mode_two_party'
       and not tgisinternal
  ) then
    raise exception
      'the two-party guard is gone from couples — modest_mode is single-party '
      'again and the screen copy is a lie';
  end if;

  if has_table_privilege('authenticated', 'public.couple_intimacy_consent', 'INSERT')
  or has_table_privilege('authenticated', 'public.couple_intimacy_consent', 'UPDATE')
  or has_table_privilege('authenticated', 'public.couple_intimacy_consent', 'DELETE')
  or has_table_privilege('authenticated', 'public.couple_intimacy_consent', 'SELECT')
  then
    raise exception
      'authenticated can reach couple_intimacy_consent directly — clearing '
      'consent on departure is worthless if a PostgREST call can write it back';
  end if;
end $do$;
