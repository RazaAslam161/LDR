-- ───────────────────────────────────────────────────────────────────────────
-- Miles — couple_members is the way back.
--
-- THE PROBLEM. `profiles.couple_id` is the only record that a couple ever
-- existed, and `leave_couple()` nulls it on both sides. From that instant the
-- dissolved couple is unaddressable: neither ex-member can name it, no policy
-- can resolve it, and `prune_dissolved_couples()` deletes it at 30 days. The
-- window in `couples.dissolved_at` is real and has no door.
--
-- REJECTED: `profiles.former_couple_id`. `20260601003300_hardening_couple_id_fix`
-- rebuilds the `authenticated` UPDATE grant on profiles from
-- information_schema at apply time, excluding ONLY `couple_id`, and the
-- migrations README makes re-running that block mandatory for any migration
-- that adds a profiles column. A pointer column there becomes client-writable
-- on the next such migration, and `guard_couple_id()` guards `couple_id`
-- alone — so one PATCH would set your pointer at any couple you can name.
-- That is the exact takeover 20260601003300 exists to close.
--
-- CHOSEN: a separate history table with NO DML grant to `authenticated` at
-- all. Every write goes through a SECURITY DEFINER trigger owned by the
-- migration role. It cannot be reached by a PostgREST PATCH by construction,
-- which is the property profiles cannot offer. Same posture as `storage_reap`
-- (RLS on, no policies, grants revoked) and `memory_threads` (no UPDATE grant,
-- RPC-only).
--
-- NOTHING BECOMES RESTORABLE IN THIS MIGRATION. It only makes a dissolved
-- couple ADDRESSABLE, and defines the one predicate that every later policy
-- and RPC will route through. The escape hatch (20260826170000) lands before
-- the restore path (20260826190000), never after — there must be no deployed
-- state in which restoration exists and the way to refuse it does not.
--
-- SELECT IS OWN-ROWS-ONLY, DELIBERATELY. A must not be able to see whether B
-- is still a member, or whether B has severed. That is what keeps the exit
-- silent: every negative answer this migration can produce is the same
-- answer.
-- ───────────────────────────────────────────────────────────────────────────

-- ── The window, in one place ───────────────────────────────────────────────
-- prune_dissolved_couples() had `interval '30 days'` as a literal, and the
-- restore path is about to need the same number. Two copies of a deadline is
-- how a couple becomes restorable for a day longer than its rows survive.
create or replace function public.dissolution_window()
returns interval language sql immutable as $$ select interval '30 days' $$;

revoke execute on function public.dissolution_window() from public, anon;
grant  execute on function public.dissolution_window() to authenticated;

-- ── The spine ──────────────────────────────────────────────────────────────
-- Both FKs carry an explicit ON DELETE. The assertion at
-- 20260601003800:70-82 raises at migration time if any FK referencing profiles
-- or couples is left at NO ACTION, because that silently blocks account
-- deletion and nothing surfaces it until a real user tries to delete.
--
-- user_id -> profiles ON DELETE CASCADE is also load-bearing for the restore
-- path: deleting an account removes the membership, so restore_couple() finds
-- fewer than two members and refuses, with no extra check to forget.
create table if not exists public.couple_members (
  couple_id  uuid not null references public.couples(id)  on delete cascade,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  joined_at  timestamptz not null default now(),
  left_at    timestamptz,
  -- Set by leave_couple_permanently() (20260826170000) on ALL rows of a couple,
  -- never just the caller's: severing binds the couple, not the person. Read
  -- here from day one as the 'severed' negative in the invariant below.
  severed_at timestamptz,
  primary key (couple_id, user_id)
);

create index if not exists couple_members_user_idx
  on public.couple_members (user_id, left_at desc);

alter table public.couple_members enable row level security;

revoke all on public.couple_members from anon, authenticated;
grant select on public.couple_members to authenticated;

drop policy if exists couple_members_own on public.couple_members;
create policy couple_members_own on public.couple_members
  for select using (user_id = (select auth.uid()));

-- ── Maintenance, on the same hook every other couple_id consumer uses ──────
-- Mirrors sync_presence_couple_id (20260601002600) and for the same stated
-- reason: it fires on every path that moves couple_id, so no future RPC can
-- forget to record a membership. OLD is unassigned during an INSERT, so the
-- TG_OP tests are nested rather than ANDed — PL/pgSQL does not promise to
-- short-circuit a boolean, and `old.couple_id` under TG_OP='INSERT' raises.
create or replace function public.sync_couple_members()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if tg_op = 'UPDATE' then
    if old.couple_id is not null
       and old.couple_id is distinct from new.couple_id then
      update public.couple_members
         set left_at = now()
       where couple_id = old.couple_id
         and user_id = new.id
         and left_at is null;
    end if;
  end if;

  if new.couple_id is not null then
    if tg_op = 'INSERT' then
      insert into public.couple_members (couple_id, user_id)
      values (new.couple_id, new.id)
      on conflict (couple_id, user_id) do update set left_at = null;
    elsif new.couple_id is distinct from old.couple_id then
      insert into public.couple_members (couple_id, user_id)
      values (new.couple_id, new.id)
      on conflict (couple_id, user_id) do update set left_at = null;
    end if;
  end if;

  return new;
end $fn$;

revoke execute on function public.sync_couple_members() from public, anon, authenticated;

drop trigger if exists profiles_sync_couple_members on public.profiles;
create trigger profiles_sync_couple_members
  after insert or update of couple_id on public.profiles
  for each row execute function public.sync_couple_members();

-- ── The single safety invariant ────────────────────────────────────────────
-- Every policy and RPC in the severance work routes through this one function,
-- so it is impossible for any of it to widen a LIVE couple's boundary or to
-- drag back somebody who has moved on. It is the one function a reviewer has
-- to read.
--
-- The final clause — the caller currently has no couple — is the whole safety
-- argument, and it belongs here rather than repeated in each caller where one
-- copy would eventually be forgotten.
create or replace function public.current_user_restorable_couple_id()
returns uuid language sql stable security definer set search_path = public as $fn$
  select cm.couple_id
    from public.couple_members cm
    join public.couples c on c.id = cm.couple_id
   where cm.user_id = (select auth.uid())
     and cm.severed_at is null
     and c.dissolved_at is not null
     and c.dissolved_at > now() - public.dissolution_window()
     and (select p.couple_id from public.profiles p
           where p.id = (select auth.uid())) is null
   order by c.dissolved_at desc
   limit 1
$fn$;

revoke execute on function public.current_user_restorable_couple_id() from public, anon;
grant  execute on function public.current_user_restorable_couple_id() to authenticated;

-- ── The read surface ───────────────────────────────────────────────────────
-- An RPC and deliberately NOT a SELECT policy on `couples`: a SELECT policy is
-- all-columns, and couples carries `stripe_customer_id` and `invite_code`,
-- neither of which an ex should ever see.
--
-- Returns NULL — one indistinguishable shape — for every negative case: not a
-- member, severed, window expired, couple already purged, or currently paired
-- with somebody else. That uniformity is the anti-oracle property: nothing an
-- ex can call ever reveals whether the other person chose the permanent exit
-- or simply let the clock run out.
create or replace function public.couple_restore_state()
returns jsonb language plpgsql stable security definer set search_path = public as $fn$
declare v_couple uuid; v_dissolved timestamptz;
begin
  v_couple := public.current_user_restorable_couple_id();
  if v_couple is null then return null; end if;
  select dissolved_at into v_dissolved from public.couples where id = v_couple;
  if v_dissolved is null then return null; end if;
  return jsonb_build_object(
    'couple_id',  v_couple,
    'dissolved_at', v_dissolved,
    'expires_at', v_dissolved + public.dissolution_window()
  );
end $fn$;

revoke execute on function public.couple_restore_state() from public, anon;
grant  execute on function public.couple_restore_state() to authenticated;

-- ── prune_dissolved_couples reads the window from one place now ────────────
-- Body is byte-for-byte the live production definition (captured with
-- pg_get_functiondef and diffed before writing this), with the single
-- `interval '30 days'` literal replaced by the function. Nothing else changes:
-- the bucket list, the storage_reap queue and the delete are untouched.
create or replace function public.prune_dissolved_couples()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_ids uuid[];
begin
  select coalesce(array_agg(id), '{}') into v_ids
    from public.couples
   where dissolved_at is not null
     and dissolved_at < now() - public.dissolution_window()
     and not exists (select 1 from public.profiles p where p.couple_id = couples.id);

  if array_length(v_ids, 1) is null then return; end if;

  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from storage.objects o
   where o.bucket_id in ('couple_media','couple_intimate','capsule-media',
                         'couple_files')
     and (storage.foldername(o.name))[1] = any (select unnest(v_ids)::text)
  on conflict do nothing;

  delete from public.couples where id = any (v_ids);
end $fn$;

revoke execute on function public.prune_dissolved_couples() from public, anon, authenticated;

-- ── Backfill: reconstruct membership for couples that already exist ────────
-- Three sources, best effort. Every one is joined back to `profiles` so a
-- source naming an account that no longer exists cannot violate the FK.
--
-- Reports counts rather than running silently, and RAISES on a couple that
-- resolved to more than two members, because that is data corruption rather
-- than a gap. Fewer than two is a WARNING, not an exception: it means the
-- couple is permanently unrestorable and the operator should know how many,
-- but it must not block the migration.
do $do$
declare v_rows int; v_short int; v_over text;
begin
  with live as (
    select p.couple_id, p.id as user_id, null::timestamptz as left_at
      from public.profiles p where p.couple_id is not null
  ), inv as (
    select i.couple_id, i.created_by as user_id, c.dissolved_at as left_at
      from public.pairing_invites i join public.couples c on c.id = i.couple_id
     where i.created_by is not null
    union
    select i.couple_id, i.consumed_by, c.dissolved_at
      from public.pairing_invites i join public.couples c on c.id = i.couple_id
     where i.consumed_by is not null and i.consumed_at is not null
  ), msg as (
    select distinct m.couple_id, m.sender_id as user_id, c.dissolved_at as left_at
      from public.messages m join public.couples c on c.id = m.couple_id
     where m.sender_id is not null
  ), merged as (
    -- left_at is min() across sources, EXCEPT for somebody who currently holds
    -- that couple_id: min() ignores nulls, so a live member who also appears in
    -- the message source would otherwise be stamped as having left. Cannot
    -- happen today (leave_couple nulls both profiles), but a derived column
    -- that is wrong only in a corner nobody reaches is still wrong.
    select s.couple_id, s.user_id,
           case when exists (select 1 from public.profiles p
                              where p.id = s.user_id and p.couple_id = s.couple_id)
                then null else min(s.left_at) end as left_at
      from (select * from live union all select * from inv union all select * from msg) s
     where exists (select 1 from public.profiles p where p.id = s.user_id)
       and exists (select 1 from public.couples  c where c.id = s.couple_id)
     group by s.couple_id, s.user_id
  )
  insert into public.couple_members (couple_id, user_id, left_at)
  select couple_id, user_id, left_at from merged
  on conflict (couple_id, user_id) do nothing;
  get diagnostics v_rows = row_count;

  select count(*) into v_short from (
    select couple_id from public.couple_members
     group by couple_id having count(*) < 2) x;

  select string_agg(couple_id::text, ', ') into v_over from (
    select couple_id from public.couple_members
     group by couple_id having count(*) > 2) y;

  if v_over is not null then
    raise exception
      'couple(s) % resolved to more than two members — membership is corrupt, '
      'not merely incomplete; do not proceed', v_over;
  end if;

  raise notice 'couple_members backfilled: % rows; couples with fewer than two '
               'members (permanently unrestorable): %', v_rows, v_short;
  if v_short > 0 then
    raise warning '% couple(s) had no second member recoverable from profiles, '
                  'invites or messages — those are permanently unrestorable',
                  v_short;
  end if;
end $do$;

-- ── The FK guard that 20260601003800 installed, re-run ─────────────────────
-- Both new foreign keys reference tables that guard covers. Re-running it here
-- means this migration fails now rather than a user's account deletion failing
-- later.
do $do$
declare n int; d text;
begin
  select count(*), coalesce(string_agg(conrelid::regclass||'.'||conname, ', '), '')
    into n, d
    from pg_constraint
   where contype = 'f'
     and confrelid in ('public.profiles'::regclass, 'public.couples'::regclass)
     and confdeltype = 'a';
  if n > 0 then
    raise exception 'account deletion is blocked by % foreign key(s) with NO ACTION: %', n, d;
  end if;
end $do$;

-- ── Assertion: couple_members is not client-writable ───────────────────────
-- The entire reason this is a separate table rather than a profiles column.
do $do$
begin
  if has_table_privilege('authenticated', 'public.couple_members', 'INSERT')
  or has_table_privilege('authenticated', 'public.couple_members', 'UPDATE')
  or has_table_privilege('authenticated', 'public.couple_members', 'DELETE')
  then
    raise exception
      'authenticated can write couple_members — the table exists precisely '
      'because membership must not be settable by a PostgREST call';
  end if;
end $do$;

-- ── ROLLBACK ───────────────────────────────────────────────────────────────
-- Drop order matters: prune_dissolved_couples must be restored to its literal
-- form BEFORE dissolution_window() is dropped, or the drop fails on the
-- dependency.
--
--   create or replace function public.prune_dissolved_couples() ...
--     -- verbatim from 20260817130000_reap_covers_thumbnails.sql:81-105,
--     -- i.e. with `interval '30 days'` in place of public.dissolution_window()
--   drop function if exists public.couple_restore_state();
--   drop function if exists public.current_user_restorable_couple_id();
--   drop trigger  if exists profiles_sync_couple_members on public.profiles;
--   drop function if exists public.sync_couple_members();
--   drop table    if exists public.couple_members;
--   drop function if exists public.dissolution_window();
--
-- Fully reversible. The only data this migration writes is couple_members,
-- which is derived — dropping the table loses nothing that the backfill could
-- not reconstruct from profiles, pairing_invites and messages.
--
-- Second run: no-op. Table and index are IF NOT EXISTS, functions are
-- create-or-replace, the policy and trigger are dropped-if-exists first, and
-- the backfill is ON CONFLICT DO NOTHING (second run inserts 0 rows).
