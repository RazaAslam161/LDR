-- Entropy for the pairing code, done again — this time inside eight characters.
--
-- 20260818130000 raised the code to twelve characters and had to be reverted
-- within the hour: the invite field on every shipped build is
-- `maxLength: 8` (couple_page.dart:274), enforced by Flutter against typed and
-- pasted input alike, so a twelve-character code was unenterable on a fleet
-- that has no update channel. That migration's banner carries the full
-- post-mortem. Nothing reached a user (zero non-8-character codes ever existed
-- on production, verified), and the two correct halves of it — the dead
-- limiter's removal and the TTL ceiling — stayed.
--
-- The real lever was never length. It was the ALPHABET.
--
--   before: 8 hex characters                 16^8  = 2^32     4.3e9
--   after:  8 characters from 34 symbols     34^8  = 2^40.7   3.9e11  (415x)
--
-- The 34 symbols are `[A-Z0-9]` — precisely what the field's own
-- `FilteringTextInputFormatter.allow(RegExp('[A-Z0-9]'))` already permits
-- (couple_page.dart:275) — minus I and O, so that nothing a partner reads
-- aloud or types can be confused with 1 or 0. Eight characters, same shape,
-- same field, no client change, and every code minted before this still
-- redeems until it expires.
--
-- Two details that matter more than they look:
--
--   RANDOMNESS. `gen_random_uuid()` is a pg_catalog builtin backed by
--   pg_strong_random, so it needs no extension. `gen_random_bytes` would have
--   been the obvious choice and is the wrong one here: pgcrypto lives in the
--   `extensions` schema, and this function pins `search_path = public` on
--   purpose. Widening that pin to reach a convenience function would trade a
--   security control for a shortcut. Hex positions 1-12 of a v4 UUID are
--   fully random (the version nibble is at 13, the variant at 17).
--
--   MODULO BIAS. 256 is not a multiple of 34, so a naive `% 34` would favour
--   the first eighteen symbols and quietly cost entropy. Bytes 238..255 are
--   rejected and redrawn, which makes the distribution exactly uniform.
--
-- Redeem also becomes forgiving in the one direction that is safe: `I` maps to
-- `1` and `O` to `0` on input. The generator never emits I or O, so a user who
-- typed one meant the digit — and for the hex codes minted before this, which
-- contain neither letter, the translation is a no-op. It cannot widen the
-- guessing space, because it changes what is ACCEPTED, not what is GENERATED.
--
-- Verified on production before this file was written, all rolled back:
--   len8=t alphabet=t distinct=300/300 typed_O_for_zero=t paired=t
--   invalid_code=t couple_full=t couple_dissolved=t
--
-- Second run: no-op (create or replace only).
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
-- Restore the generator's loop body to the 8-hex form and drop the translate:
--
--   v_code := upper(substr(replace(gen_random_uuid()::text,'-',''), 1, 8));
--   v_clean text := upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g'));
--
-- Everything else in both functions is unchanged from 20260818130000, whose
-- own rollback block restores the state before that.
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.create_pairing_invite(p_ttl_minutes integer default 60)
returns pairing_invites language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_couple uuid;
  v_code text;
  v_pool text;
  v_byte int;
  i int;
  v_row public.pairing_invites;
  -- 34 symbols: [A-Z0-9] is exactly what the invite field's own filter allows
  -- (couple_page.dart:275), minus I and O so nothing can be misread as 1 or 0
  -- in a code a partner types by hand. Eight of these is 40.7 bits against
  -- hex's 32 — 415x the space, in the same eight characters every shipped
  -- client can already accept.
  v_alphabet constant text := '0123456789ABCDEFGHJKLMNPQRSTUVWXYZ';
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
    v_code := '';
    while length(v_code) < 8 loop
      -- gen_random_uuid() is a pg_catalog builtin backed by pg_strong_random,
      -- so this needs no extension and no widening of the pinned search_path
      -- (gen_random_bytes lives in `extensions`, which this function
      -- deliberately cannot see). Hex positions 1-12 are fully random: the
      -- version nibble sits at 13 and the variant at 17.
      v_pool := substr(replace(gen_random_uuid()::text, '-', ''), 1, 12);
      for i in 0..5 loop
        exit when length(v_code) >= 8;
        v_byte := ('x' || substr(v_pool, i * 2 + 1, 2))::bit(8)::int;
        -- Reject 238..255 so the modulo cannot favour the first 18 symbols.
        if v_byte < 238 then
          v_code := v_code || substr(v_alphabet, (v_byte % 34) + 1, 1);
        end if;
      end loop;
    end loop;
    exit when not exists (select 1 from public.pairing_invites where code = v_code);
  end loop;

  insert into public.pairing_invites (code, couple_id, created_by, expires_at)
  values (v_code, v_couple, v_uid,
          now() + make_interval(
            mins => least(greatest(coalesce(p_ttl_minutes, 60), 1), 1440)))
  returning * into v_row;

  return v_row;
end $fn$;

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
