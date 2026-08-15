-- A code printed before the break-up must not open the door after it.
--
-- Three things were true at once. leave_couple never touched pairing_invites,
-- so every code handed out while they were together stayed live. redeem_
-- pairing_invite refused a couple only for being FULL, and a dissolved couple
-- has no members, so it read as empty. And clear_dissolved_on_join then set
-- active = true and dissolved_at = null, which is the reconciliation path but
-- also permanently cancels the 30-day purge.
--
-- Chained: anyone still holding an unconsumed code joins the couple that no
-- longer exists, inherits current_user_couple_id(), and every RLS policy in
-- the schema hands them the retained history of two other people.
--
-- Reconciliation does not need this door. create_pairing_invite calls
-- create_couple when the caller has no couple_id — and leave_couple nulls
-- couple_id for both of them — so re-pairing has always built a NEW couple.
-- The only thing that could still reach the old one was a stale code.

create or replace function public.leave_couple()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_uid uuid := auth.uid(); v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then return; end if;
  update public.profiles set couple_id = null where couple_id = v_couple;
  -- consumed_by stays null: nobody redeemed these, the couple ended under them.
  update public.pairing_invites set consumed_at = now()
   where couple_id = v_couple and consumed_at is null;
  update public.couples
     set active = false,
         -- Starts the clock. Re-pairing clears it, so a reconciliation inside
         -- the window keeps everything.
         dissolved_at = coalesce(dissolved_at, now())
   where id = v_couple;
end $fn$;

create or replace function public.redeem_pairing_invite(p_code text)
returns public.couples language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_clean text := upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g'));
  v_invite public.pairing_invites;
  v_couple public.couples;
  v_my_couple uuid;
  v_count int;
  v_fails int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select count(*) into v_fails
    from public.pairing_attempts
   where user_id = v_uid and not ok
     and attempted_at > now() - interval '15 minutes';
  if v_fails >= 10 then raise exception 'too_many_attempts'; end if;

  select couple_id into v_my_couple from public.profiles where id = v_uid;
  select * into v_invite from public.pairing_invites where code = v_clean;

  if not found or v_invite.consumed_at is not null or v_invite.expires_at < now() then
    insert into public.pairing_attempts (user_id, ok) values (v_uid, false);
    raise exception 'invalid_code';
  end if;

  if v_my_couple = v_invite.couple_id then
    insert into public.pairing_attempts (user_id, ok) values (v_uid, true);
    select * into v_couple from public.couples where id = v_invite.couple_id;
    return v_couple;
  end if;

  -- The second belt to leave_couple's braces: a code minted before this
  -- migration is still live in the table and still points at a dead couple.
  if exists (select 1 from public.couples
              where id = v_invite.couple_id and dissolved_at is not null) then
    insert into public.pairing_attempts (user_id, ok) values (v_uid, false);
    raise exception 'couple_dissolved';
  end if;

  select count(*) into v_count from public.profiles where couple_id = v_invite.couple_id;
  if v_count >= 2 then
    insert into public.pairing_attempts (user_id, ok) values (v_uid, false);
    raise exception 'couple_full';
  end if;

  update public.profiles set couple_id = v_invite.couple_id where id = v_uid;
  update public.pairing_invites set consumed_at = now(), consumed_by = v_uid
   where code = v_clean;
  insert into public.pairing_attempts (user_id, ok) values (v_uid, true);

  if v_my_couple is not null
     and not exists (select 1 from public.profiles  where couple_id = v_my_couple)
     and not exists (select 1 from public.messages  where couple_id = v_my_couple)
     and not exists (select 1 from public.vault_items where couple_id = v_my_couple)
     and not exists (select 1 from public.capsules  where couple_id = v_my_couple)
     and not exists (select 1 from public.visits    where couple_id = v_my_couple)
     and not exists (select 1 from public.memory_threads where couple_id = v_my_couple)
  then
    delete from public.couples where id = v_my_couple;
  end if;

  select * into v_couple from public.couples where id = v_invite.couple_id;
  return v_couple;
end $fn$;

-- Codes already loose against couples that are already dead.
update public.pairing_invites i set consumed_at = now()
  from public.couples c
 where c.id = i.couple_id and c.dissolved_at is not null and i.consumed_at is null;
