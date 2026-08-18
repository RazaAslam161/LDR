-- ⚠ SUPERSEDED IN PART, THE SAME DAY, BY 20260818180000.
--
-- The entropy half of this migration was WRONG and was reverted within the
-- hour. It raised codes to twelve characters on the strength of "the client
-- validates nothing but non-empty (couple_page.dart:93)". That citation is
-- real but it is the EMPTINESS check; the invite field is capped 181 lines
-- further down at `maxLength: 8` (couple_page.dart:274), which Flutter
-- enforces against typed AND pasted input. Twelve-character codes could not
-- be entered on any build in the field, and this app is sideloaded with no
-- update channel — the exact "no fix may depend on clients upgrading" rule
-- this repo keeps at the top of its list. Nobody was affected (zero
-- twelve-character codes ever reached a user; verified on production), but
-- only because the window was minutes.
--
-- WHAT SURVIVES FROM THIS FILE: the removal of the dead limiter, and the TTL
-- ceiling. Both are correct and both stayed.
-- WHAT 20260818180000 REPLACED: the code generator, which now produces EIGHT
-- characters from a 34-symbol alphabet — more entropy than the twelve-hex
-- attempt was worth reaching for, inside a length every shipped client
-- already accepts.
--
-- The lesson, written where the next person will hit it: "server-only" is a
-- claim about the CLIENT, and it is not proven by reading one line of the
-- client. Read the widget that owns the field.
--
-- The pairing brute-force limiter has never fired, and could not have.
--
-- Root cause, one sentence: every failure path inserts a row into
-- pairing_attempts and then `raise exception`s, and Postgres rolls that insert
-- back with the exception in the same transaction — so `select count(*) ...
-- where not ok` can only ever see zero, and the "10 failures in 15 minutes"
-- gate is dead code that reads like a control.
--
-- Proven on production 2026-08-18, not inferred:
--   select count(*) filter (where not ok) as failure_rows,
--          count(*) filter (where ok)     as success_rows
--     from public.pairing_attempts;
--   -> failure_rows 0, success_rows 1
-- Months of use, including failed redeems, and not one failure was recorded.
--
-- WHY IT IS NOT SIMPLY REPAIRED
-- PostgREST runs each RPC in one transaction. Within it there is no way to
-- persist a write that must survive the rollback the error itself causes:
-- plpgsql has no autonomous transactions, an EXCEPTION handler's writes die
-- with the re-raise, and pg_net's queue insert is transactional too. The only
-- in-database escapes are a separate connection (dblink, whose credential
-- would then live in this database) or not raising at all — and the shipped
-- clients read these exceptions by message
-- (supabase_repository.dart:607-620), so a function that stops raising tells
-- every installed phone that a failed pairing succeeded. Neither is worth it
-- for a counter.
--
-- WHAT REPLACES IT
-- Entropy, which needs no state and therefore cannot be rolled back:
--
--   codes go from 8 hex characters to 12 -> 2^32 to 2^48, 65,536x the space.
--
-- At 2^48 (281 trillion) against single-use codes that expire, guessing is not
-- a threat a counter needs to catch. This is a SERVER-ONLY change: the column
-- is `text` with no length limit, the client validates nothing but non-empty
-- (couple_page.dart:93) and sends exactly what was typed, and redeem already
-- strips whitespace and uppercases. Every shipped APK keeps working, and codes
-- minted before this migration keep working until they expire.
--
-- Second: the TTL gains an upper bound. `greatest(coalesce(p_ttl_minutes,60),1)`
-- had a floor and no ceiling, so a caller could mint a code that outlives the
-- couple. Capped at 1440 minutes — the value the shipped client already asks
-- for, so nothing legitimate changes.
--
-- The dead inserts and the dead check are REMOVED rather than left in place.
-- A control that cannot work is worse than no control: it is the thing the
-- next audit reads and ticks off. The truth is written here and in the
-- function body so nobody re-adds it believing otherwise. The SUCCESS insert
-- stays — it commits, and it is the genuine audit trail of who paired when.
--
-- Second run: no-op (create or replace only).
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
-- Both bodies below were captured from production with pg_get_functiondef
-- immediately before this migration replaced them. Restoring them restores an
-- 8-character code space and a limiter that does not work.
--
--   create or replace function public.create_pairing_invite(p_ttl_minutes integer default 60)
--   returns pairing_invites language plpgsql security definer set search_path to 'public'
--   as $rollback$
--   declare
--     v_uid uuid := auth.uid(); v_couple uuid; v_code text; v_row public.pairing_invites;
--   begin
--     if v_uid is null then raise exception 'not_authenticated'; end if;
--     select couple_id into v_couple from public.profiles where id = v_uid;
--     if v_couple is null then
--       select id into v_couple from public.create_couple(coalesce(
--         (select timezone from public.profiles where id = v_uid), 'UTC'));
--     end if;
--     if v_couple is null then raise exception 'no_couple'; end if;
--     loop
--       v_code := upper(substr(replace(gen_random_uuid()::text,'-',''), 1, 8));
--       exit when not exists (select 1 from public.pairing_invites where code = v_code);
--     end loop;
--     insert into public.pairing_invites (code, couple_id, created_by, expires_at)
--     values (v_code, v_couple, v_uid,
--             now() + make_interval(mins => greatest(coalesce(p_ttl_minutes, 60), 1)))
--     returning * into v_row;
--     return v_row;
--   end $rollback$;
--
--   -- redeem_pairing_invite: the pre-migration body is the one in
--   -- 20260815071024_invites_die_with_the_couple.sql:38, unchanged. Restore it
--   -- verbatim from that file.
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.create_pairing_invite(p_ttl_minutes integer default 60)
returns pairing_invites language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_couple uuid;
  v_code text;
  v_row public.pairing_invites;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select couple_id into v_couple from public.profiles where id = v_uid;

  if v_couple is null then
    select id into v_couple
    from public.create_couple(coalesce(
      (select timezone from public.profiles where id = v_uid), 'UTC'
    ));
  end if;

  if v_couple is null then raise exception 'no_couple'; end if;

  loop
    -- Twelve hex characters, 48 bits, from a v4 UUID's CSPRNG. Positions 1-12
    -- are all random: the version nibble sits at position 13 and the variant
    -- at 17, so neither is borrowed here and the space is the full 2^48.
    v_code := upper(substr(replace(gen_random_uuid()::text,'-',''), 1, 12));
    exit when not exists (select 1 from public.pairing_invites where code = v_code);
  end loop;

  insert into public.pairing_invites (code, couple_id, created_by, expires_at)
  values (v_code, v_couple, v_uid,
          -- Floor of one minute, ceiling of a day. The ceiling is new: without
          -- it a caller could ask for a code that never expires, which is the
          -- one input that turns a guessing budget into an unlimited one.
          now() + make_interval(
            mins => least(greatest(coalesce(p_ttl_minutes, 60), 1), 1440)))
  returning * into v_row;

  return v_row;
end $fn$;

create or replace function public.redeem_pairing_invite(p_code text)
returns couples language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_clean text := upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g'));
  v_invite public.pairing_invites;
  v_couple public.couples;
  v_my_couple uuid;
  v_count int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  -- There is deliberately no failed-attempt limiter here.
  --
  -- One used to sit at this line, counting rows in pairing_attempts. It could
  -- never fire: the rows it counted were written on paths that raise, and the
  -- raise rolls the write back. Production held 0 failure rows after months.
  -- Anything counted in this transaction dies with the error that ends it, and
  -- the alternatives — a second connection holding a credential, or a function
  -- that stops raising and so tells shipped clients a failure succeeded — both
  -- cost more than they buy. The defence is the code space above: 2^48,
  -- single-use, and expiring within a day. Do not re-add a counter here
  -- without first solving the rollback, or the next audit will tick off a
  -- control that does nothing.

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
  -- Commits, unlike the failure rows this table used to pretend to hold. It is
  -- an audit trail of pairings, and it is honest about being only that.
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
