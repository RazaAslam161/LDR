-- ───────────────────────────────────────────────────────────────────────────
-- Miles — defects that only bite users who sign up AFTER the earlier
-- migrations ran. Idempotent; safe to re-run. No data deleted.
--
-- Each of these looked fixed because the fix was written as a one-time
-- backfill against the rows that existed that day, or was never exercised by
-- the two accounts already in the database.
-- ───────────────────────────────────────────────────────────────────────────

-- ── 1. CRITICAL: the joining partner could never delete their account ──────
-- pairing_invites.consumed_by references profiles(id) with no ON DELETE
-- action, so it defaults to NO ACTION. delete_my_account deletes the auth
-- user, that cascades to profiles, and the FK then aborts the whole
-- transaction. In EVERY new couple exactly one person is the joiner, so
-- account deletion — which Play requires — was guaranteed to fail for half of
-- all users, permanently, with a foreign-key error.
alter table public.pairing_invites
  drop constraint if exists pairing_invites_consumed_by_fkey;
alter table public.pairing_invites
  add constraint pairing_invites_consumed_by_fkey
  foreign key (consumed_by) references public.profiles(id) on delete set null;

-- Same class, same table: created_by would block the INVITER's deletion.
do $$
declare r record;
begin
  for r in
    select conname, conrelid::regclass as tbl,
           pg_get_constraintdef(oid) as def
      from pg_constraint
     where contype = 'f'
       and confrelid = 'public.profiles'::regclass
       and confdeltype = 'a'          -- NO ACTION: blocks the delete
  loop
    raise notice 'FK with NO ACTION on profiles: %.% -> %',
      r.tbl, r.conname, r.def;
  end loop;
end $$;

-- ── 2. HIGH: pairing still minted a permanent 6-character code ────────────
-- hardening_2026_08.sql nulled the two codes that existed and called it
-- retired, but never touched the generator. Every couple formed since has a
-- fresh permanent, never-rotated, never-expiring code sitting in the column
-- the migration claimed to have emptied. Textbook "fixed the data, not the
-- code path". join_couple_by_code is gone so nothing reads it today, which is
-- precisely why it would sit there unnoticed until someone adds a lookup.
create or replace function public.create_pairing_invite(p_ttl_minutes integer)
returns public.pairing_invites language plpgsql security definer
set search_path = public as $$
declare
  v_uid       uuid := auth.uid();
  v_couple_id uuid;
  v_code      text;
  v_row       public.pairing_invites%rowtype;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select couple_id into v_couple_id from public.profiles where id = v_uid;
  if v_couple_id is null then
    -- No invite_code: the column is retired and nothing reads it.
    insert into public.couples (primary_tz) values (null)
      returning id into v_couple_id;
    update public.profiles set couple_id = v_couple_id where id = v_uid;
  end if;

  -- 8 chars from a 32-symbol alphabet = 40 bits, versus 24 bits before, and
  -- unlike couples.invite_code this one expires and is single-use.
  loop
    select string_agg(substr('ABCDEFGHJKMNPQRSTUVWXYZ23456789', 1 + floor(random() * 31)::int, 1), '')
      into v_code from generate_series(1, 8);
    begin
      insert into public.pairing_invites (code, couple_id, created_by, expires_at)
      values (v_code, v_couple_id, v_uid,
              now() + make_interval(mins => greatest(coalesce(p_ttl_minutes, 60), 1)))
      returning * into v_row;
      exit;
    exception when unique_violation then
      null; -- 40 bits: a collision is a lottery win, but handle it anyway
    end;
  end loop;
  return v_row;
end; $$;
revoke execute on function public.create_pairing_invite(integer) from public, anon;
grant  execute on function public.create_pairing_invite(integer) to authenticated;

-- Retire any codes minted since the earlier migration.
update public.couples set invite_code = null where invite_code is not null;

-- ── 3. A receipt row for every couple, from the server ────────────────────
-- receipts_v2.sql seeded only the profiles that existed the day it ran, so a
-- couple formed tomorrow depended entirely on a client ack to create theirs.
-- The ack does self-create, so this is a floor rather than a repair: it means
-- a missing double-tick can never be caused by a missing row.
create or replace function public.init_chat_receipt()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.couple_id is not null then
    insert into public.chat_receipts (couple_id, user_id)
    values (new.couple_id, new.id)
    on conflict (couple_id, user_id) do nothing;
  end if;
  return new;
end; $$;
revoke execute on function public.init_chat_receipt() from public, anon, authenticated;

drop trigger if exists trg_init_chat_receipt on public.profiles;
create trigger trg_init_chat_receipt
  after insert or update of couple_id on public.profiles
  for each row execute function public.init_chat_receipt();

-- Catch up anyone who paired between receipts_v2.sql and this file.
insert into public.chat_receipts (couple_id, user_id)
select couple_id, id from public.profiles where couple_id is not null
on conflict (couple_id, user_id) do nothing;

-- ── 4. leave_couple's privacy wipe must survive the new presence trigger ──
-- presence_stamp_server_time replaces app_last_active_at with now() whenever
-- the value changes — including the deliberate NULL that leave_couple writes
-- to stop an ex-partner reading a live last-seen. A NULL is an erasure, not
-- an activity stamp, so exempt it.
create or replace function public.presence_stamp_server_time()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();

  if new.app_last_active_at is null then
    return new;              -- deliberate erasure (leave_couple); leave it
  end if;

  if tg_op = 'INSERT' then
    new.app_last_active_at := now();
  elsif new.app_last_active_at is distinct from old.app_last_active_at then
    new.app_last_active_at := now();
  end if;

  return new;
end $$;
