-- ───────────────────────────────────────────────────────────────────────────
-- Miles — Closer opens only when both of them say so.
--
-- THE LIE THIS CLOSES. closer_screen.dart printed, under the candle, "It stays
-- off until both of you turn it on in Settings" — over a schema where
-- `couples.modest_mode` is ONE boolean on ONE row and 20260815071520 grants
-- UPDATE on that exact column to `authenticated`. Either partner flipped it
-- alone, from the Settings switch or from a raw PATCH, and the other one's
-- first notice was Closer already being open on their phone. The repository's
-- own doc comment admitted it ("the schema permits either partner to flip it")
-- and 20260601001200's column comment asserted the opposite ("Both must opt
-- out to reveal it"). Three places describing three different products.
--
-- ADDITIVE, BECAUSE BUILDS 49-64 ARE ON REAL HANDSETS. `couples.modest_mode`
-- keeps its name, its type, its default and its UPDATE grant. Seven client
-- readers (app_shell, app_drawer, chat_screen, settings_screen,
-- closer_screen, screen_presence, presence_route_observer) and every shipped
-- build go on reading exactly the column they read yesterday. What changes is
-- who gets to WRITE it: it becomes a DERIVED value that only this migration's
-- code sets, from a new per-member consent table beside it.
--
-- REJECTED: revoking the modest_mode UPDATE grant. That is the honest shape
-- and it breaks every installed build — the Settings toggle would throw a
-- permission error the client has no string for, on a fleet with no forced
-- update. So the grant stays and the BEFORE trigger below reinterprets what
-- an old client's write MEANS: `modest_mode = false` from a signed-in member
-- is that member's consent, not the couple's decision. An old build toggling
-- Closer on now records consent and leaves the flag alone until the partner
-- agrees — which is precisely the sentence its own screen was already
-- printing. The old clients become correct without being updated.
--
-- REJECTED: a second boolean column on `couples` (…_a_consented / …_b). The
-- couple row has no stable notion of "A" and "B", the column would be inside
-- the same all-columns UPDATE grant, and 20260826160000 already argued this
-- out for membership: a separate table with NO DML grant to `authenticated`
-- cannot be reached by a PostgREST PATCH by construction. Same posture here.
--
-- TWO MEMBERS, NOT "AT LEAST ONE". The effective state opens only when the
-- couple has exactly two live members and BOTH have consented. A couple of one
-- can therefore never open Closer alone, which is the point: the promise names
-- a partner. It also means the flag closes by itself when someone leaves — the
-- profiles hook below recomputes on every couple_id move, so a departure is
-- not a state where one person's consent still speaks for two.
--
-- Second run: no-op. Table and index are IF NOT EXISTS, every function is
-- CREATE OR REPLACE, both triggers are DROP IF EXISTS before CREATE, and the
-- one-time reconciliation at the bottom is an UPDATE whose predicate is
-- already false the second time.
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
-- Drop order matters: the triggers must go before the functions they call.
--
--   drop trigger  if exists couples_modest_mode_two_party on public.couples;
--   drop trigger  if exists profiles_sync_intimacy_modest on public.profiles;
--   drop function if exists public.set_intimacy_consent(boolean);
--   drop function if exists public.intimacy_consent_state();
--   drop function if exists public.sync_intimacy_modest();
--   drop function if exists public.guard_modest_mode();
--   drop function if exists public.recompute_intimacy_modest(uuid);
--   drop function if exists public.intimacy_effective_modest(uuid);
--   drop table    if exists public.couple_intimacy_consent;
--
-- `couples.modest_mode` is left holding whatever value the derivation last
-- wrote, and after the drop it is a plain client-writable boolean again —
-- exactly the pre-migration behaviour, including the defect. Nothing here
-- retypes, renames or drops an existing column, so a rolled-back database is
-- byte-compatible with every build from 49 up. The only data lost is the
-- consent table, which is not derivable from anything else: EXPORT IT FIRST
-- if the rollback is meant to be re-applied.
--
--   create table couple_intimacy_consent_backup as
--     select * from public.couple_intimacy_consent;
-- ───────────────────────────────────────────────────────────────────────────

-- ── The consent, one row per member ────────────────────────────────────────
-- No DML grant to `authenticated` at all, and not even SELECT: the read
-- surface is intimacy_consent_state() below. The argument is 20260826160000's
-- — a table nobody can PATCH cannot be written wrong — plus the one from
-- couple_restore_state(): a SELECT policy is all-columns, and an RPC returning
-- two booleans is the whole thing a screen needs.
--
-- Both FKs carry an explicit ON DELETE, per the assertion at
-- 20260601003800:70-82. user_id -> profiles ON DELETE CASCADE is load-bearing:
-- a deleted account takes its consent with it, so the survivor's couple falls
-- back to modest by derivation rather than by a cleanup step somebody has to
-- remember.
create table if not exists public.couple_intimacy_consent (
  couple_id  uuid not null references public.couples(id)  on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  consented  boolean not null default false,
  updated_at timestamptz not null default now(),
  primary key (couple_id, user_id)
);

create index if not exists couple_intimacy_consent_user_idx
  on public.couple_intimacy_consent (user_id);

alter table public.couple_intimacy_consent enable row level security;

revoke all on public.couple_intimacy_consent from anon, authenticated;

comment on table public.couple_intimacy_consent is
  'Per-member consent to the Closer module. couples.modest_mode is DERIVED '
  'from this table and must not be written directly — the BEFORE trigger on '
  'couples turns a direct write into the writer''s own consent. Written only '
  'by set_intimacy_consent() and by that trigger.';

-- ── The derivation, in one place ───────────────────────────────────────────
-- Exactly two live members, both consenting, or the answer is modest. Exactly
-- two rather than "two or more": redeem_pairing_invite caps a couple at two
-- (20260829145343), so any other count is corruption, and corruption must
-- resolve to the closed state rather than the open one.
--
-- Consent is joined back to `profiles` so a stale row belonging to somebody
-- who has since left the couple cannot be counted as one of the two.
create or replace function public.intimacy_effective_modest(p_couple uuid)
returns boolean language sql stable security definer set search_path = public as $fn$
  select p_couple is null
      or (select count(*) from public.profiles p where p.couple_id = p_couple) <> 2
      or (select count(*)
            from public.couple_intimacy_consent ic
            join public.profiles p on p.id = ic.user_id
           where ic.couple_id = p_couple
             and p.couple_id  = p_couple
             and ic.consented) <> 2
$fn$;

-- Not granted to `authenticated`, unlike most helpers here: it takes a couple
-- id off its argument list, so a grant would answer "is that couple's Closer
-- open" for any uuid a caller can guess. The client reaches the same answer
-- through intimacy_consent_state(), which takes no couple at all.
revoke execute on function public.intimacy_effective_modest(uuid)
  from public, anon, authenticated;

-- ── Writing the derived value back onto the column old builds read ─────────
-- The transaction-local GUC is what stops the guard trigger from treating
-- THIS write as a partner's opinion. Set local, so it dies with the
-- transaction, and cleared immediately after so no later statement in the same
-- transaction inherits the bypass.
create or replace function public.recompute_intimacy_modest(p_couple uuid)
returns boolean language plpgsql security definer set search_path = public as $fn$
declare v_modest boolean;
begin
  if p_couple is null then return true; end if;
  v_modest := public.intimacy_effective_modest(p_couple);
  perform set_config('miles.intimacy_recompute', '1', true);
  update public.couples set modest_mode = v_modest
   where id = p_couple and modest_mode is distinct from v_modest;
  perform set_config('miles.intimacy_recompute', '', true);
  return v_modest;
end $fn$;

revoke execute on function public.recompute_intimacy_modest(uuid)
  from public, anon, authenticated;

-- ── The guard: nobody flips this alone, including builds 49-64 ─────────────
-- BEFORE UPDATE OF modest_mode, so it fires only when a statement actually
-- names the column — leave_couple's dissolved_at write and the pruner never
-- reach it.
--
-- auth.uid() null means service role, the migration role, or a cron job: not a
-- partner, no consent to record, and the write passes through untouched. That
-- is deliberate, and it is also the repair hatch — an operator can still force
-- the column if the derivation is ever wrong.
create or replace function public.guard_modest_mode()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare v_uid uuid := auth.uid();
begin
  -- recompute_intimacy_modest() is the only writer that already knows the
  -- derived answer; anything else is an opinion that has to be recorded as one.
  if coalesce(current_setting('miles.intimacy_recompute', true), '') = '1' then
    return new;
  end if;
  if new.modest_mode is not distinct from old.modest_mode then
    return new;
  end if;
  if v_uid is null then
    return new;
  end if;

  -- `modest_mode = false` from a member is "I want Closer on"; true is
  -- withdrawal. This is what makes an installed build correct without being
  -- updated: its Settings switch now records consent instead of deciding for
  -- two people.
  insert into public.couple_intimacy_consent (couple_id, user_id, consented, updated_at)
  values (new.id, v_uid, not new.modest_mode, now())
  on conflict (couple_id, user_id)
    do update set consented = excluded.consented, updated_at = now();

  -- Computed AFTER the upsert, which is visible to it inside this
  -- transaction. Assigned to NEW rather than issued as a second UPDATE: a
  -- nested UPDATE of the row a BEFORE trigger is already on is how "tuple to
  -- be updated was already modified" reaches a user's Settings screen.
  new.modest_mode := public.intimacy_effective_modest(new.id);
  return new;
end $fn$;

revoke execute on function public.guard_modest_mode() from public, anon, authenticated;

drop trigger if exists couples_modest_mode_two_party on public.couples;
create trigger couples_modest_mode_two_party
  before update of modest_mode on public.couples
  for each row execute function public.guard_modest_mode();

-- ── Membership moves, so the derived value moves with it ───────────────────
-- Same hook sync_couple_members (20260826160000) hangs on, and for the same
-- stated reason: it fires on every path that moves couple_id, so no future RPC
-- can forget. Without it, a couple whose partner left would keep the open flag
-- one person's consent no longer justifies.
--
-- OLD is unassigned during an INSERT, so the TG_OP test is nested rather than
-- ANDed — PL/pgSQL does not promise to short-circuit a boolean.
create or replace function public.sync_intimacy_modest()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if tg_op = 'UPDATE' then
    if old.couple_id is not null
       and old.couple_id is distinct from new.couple_id then
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
  after insert or update of couple_id on public.profiles
  for each row execute function public.sync_intimacy_modest();

-- ── The write surface: only ever the caller's own half ─────────────────────
-- p_enabled is stated in the screen's vocabulary — true means "I want Closer
-- on" — so no caller has to remember that the stored column is inverted.
--
-- The couple is read from the caller's own profile, never taken off the wire.
-- That is the whole least-privilege argument: there is no couple_id parameter
-- to point somewhere else, which is the defect 20260829145343 spent three
-- sections closing on other tables.
create or replace function public.set_intimacy_consent(p_enabled boolean)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare v_uid uuid := auth.uid(); v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then raise exception 'no_active_couple'; end if;

  insert into public.couple_intimacy_consent (couple_id, user_id, consented, updated_at)
  values (v_couple, v_uid, coalesce(p_enabled, false), now())
  on conflict (couple_id, user_id)
    do update set consented = excluded.consented, updated_at = now();

  perform public.recompute_intimacy_modest(v_couple);
  return public.intimacy_consent_state();
end $fn$;

revoke execute on function public.set_intimacy_consent(boolean) from public, anon;
grant  execute on function public.set_intimacy_consent(boolean) to authenticated;

-- ── The read surface ───────────────────────────────────────────────────────
-- Returns the partner's half as well, and that is not a leak: it is the one
-- fact the screen has to have to say "waiting for them" instead of repeating
-- the instruction. Consent to a shared module inside a live couple is a joint
-- decision by definition — unlike couple_restore_state(), whose whole design
-- is to reveal nothing about the other side.
--
-- NULL couple returns nulls rather than raising: an unpaired account opening
-- the screen is an ordinary state, not an error to render as one.
create or replace function public.intimacy_consent_state()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare v_uid uuid := auth.uid(); v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  return jsonb_build_object(
    'couple_id', v_couple,
    'mine', coalesce((select ic.consented from public.couple_intimacy_consent ic
                       where ic.couple_id = v_couple and ic.user_id = v_uid), false),
    'partner', coalesce((select ic.consented
                           from public.couple_intimacy_consent ic
                           join public.profiles p on p.id = ic.user_id
                          where ic.couple_id = v_couple
                            and p.couple_id  = v_couple
                            and ic.user_id  <> v_uid
                          limit 1), false),
    'members', (select count(*) from public.profiles p where p.couple_id = v_couple),
    'modest', public.intimacy_effective_modest(v_couple)
  );
end $fn$;

revoke execute on function public.intimacy_consent_state() from public, anon;
grant  execute on function public.intimacy_consent_state() to authenticated;

comment on column public.couples.modest_mode is
  'DERIVED since 20260829160000: true unless the couple has exactly two live '
  'members and both hold consent in couple_intimacy_consent. Still readable '
  'and still granted UPDATE for builds 49-64, but a direct write is '
  'reinterpreted as the writer''s own consent by couples_modest_mode_two_party '
  'and the stored value is recomputed. Write through set_intimacy_consent().';

-- ── Reconciliation: every couple already open on one person's say-so ───────
-- The production database was emptied on 2026-08-29, so this touches nothing
-- there and is written for the staging project and for any restore of an older
-- dump. A couple sitting at modest_mode = false has no consent rows at all,
-- because the table did not exist until three statements ago — so the honest
-- answer for every one of them is modest, and the derivation already says so.
--
-- Counts are reported rather than assumed: a reconciliation that silently
-- touches zero rows on a database that should have had some is a finding, not
-- a success.
do $do$
declare v_rows int; v_open int; v_left int;
begin
  select count(*) into v_open from public.couples where not modest_mode;

  perform set_config('miles.intimacy_recompute', '1', true);
  update public.couples c
     set modest_mode = public.intimacy_effective_modest(c.id)
   where c.modest_mode is distinct from public.intimacy_effective_modest(c.id);
  get diagnostics v_rows = row_count;
  perform set_config('miles.intimacy_recompute', '', true);

  -- Asked again AFTER the update rather than inferred from the row count: on a
  -- second run every couple already agrees and 0 rows is the correct answer,
  -- so "0 touched" is only a finding when a disagreement survives it.
  select count(*) into v_left from public.couples c
   where c.modest_mode is distinct from public.intimacy_effective_modest(c.id);

  raise notice 'intimacy consent: % couple(s) open on entry, % row(s) '
               'reconciled, % still disagreeing', v_open, v_rows, v_left;
  if v_left > 0 then
    raise exception 'intimacy_effective_modest disagrees with % couple row(s) '
                    'it just wrote — the derivation is not deterministic', v_left;
  end if;
end $do$;

-- ── Assertions ─────────────────────────────────────────────────────────────
-- Read-only. The privilege check is the negative test for the new table: a
-- third identity holding nothing but `authenticated` must not be able to write
-- one row of somebody's consent, and that is a property of the grants rather
-- than of any policy, so it is checkable here rather than only from a client.
do $do$
begin
  if has_table_privilege('authenticated', 'public.couple_intimacy_consent', 'INSERT')
  or has_table_privilege('authenticated', 'public.couple_intimacy_consent', 'UPDATE')
  or has_table_privilege('authenticated', 'public.couple_intimacy_consent', 'DELETE')
  or has_table_privilege('authenticated', 'public.couple_intimacy_consent', 'SELECT')
  then
    raise exception
      'authenticated can reach couple_intimacy_consent directly — the table '
      'exists precisely because consent must not be settable, or readable, '
      'by a PostgREST call';
  end if;

  -- The grant builds 49-64 depend on. If a later migration ever removes it,
  -- every installed Settings toggle starts throwing a permission error the
  -- client has no string for, and this is where that gets caught.
  if not has_column_privilege('authenticated', 'public.couples', 'modest_mode', 'UPDATE')
  then
    raise exception
      'authenticated lost UPDATE on couples.modest_mode — builds 49-64 write '
      'that column directly and the guard trigger depends on being able to '
      'reinterpret the write';
  end if;

  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.couples'::regclass
       and tgname = 'couples_modest_mode_two_party'
       and not tgisinternal
  ) then
    raise exception 'the two-party guard is not on couples — modest_mode is '
                    'single-party again and the screen copy is a lie';
  end if;
end $do$;
