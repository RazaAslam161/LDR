-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the vault PIN can be CHANGED, and only by someone who knows it.
--
-- The vault PIN could be set once and never changed: `set_vault_pin`,
-- `verify_vault_pin`, `has_vault_pin`, and nothing else. This adds the missing
-- verb and closes the hole that adding it would otherwise open.
--
-- WHY THE OLD PIN HAS TO BE PROVED HERE, SERVER-SIDE
--
-- `set_vault_pin` re-keys the vault with no proof of the current PIN. Reachable
-- only by an already-authenticated session, so it is not a route to data the
-- caller could not already read — `personal_vault_items` is owner-only RLS and
-- that same session can select it. What it IS is a silent re-key: someone with
-- a borrowed session can lock the owner out of their own vault, and the owner
-- finds out by being refused at a PIN they have always used.
--
-- So a change verb that just called `set_vault_pin` would be the whole feature
-- and none of the safety. This proves the old PIN against the stored bcrypt
-- hash before it writes anything.
--
-- AND WHY IT MUST DO THE LOCKOUT ACCOUNTING TOO
--
-- This is the subtle half. A change endpoint that checks the old PIN but does
-- NOT count failures is an unthrottled oracle for that PIN: 10,000 guesses at
-- four digits, with `verify_vault_pin`'s 5-try / 15-minute lockout standing
-- beside it doing nothing, because the guessing goes through the other door.
-- The accounting below is deliberately identical to `verify_vault_pin`'s, and
-- it writes to the same counters, so the two doors share one lockout.
--
-- NOTHING IS RE-ENCRYPTED
--
-- The vault's encryption key is HKDF-derived from the device's X25519 seed
-- under the label `miles-vault-v1` (CryptoCore.exportVaultKeyBytes) — it has
-- never been derived from the PIN. The PIN is a gate, not a key. So changing it
-- re-hashes one row and touches no object in storage.
--
-- STATE OF THE TREE THIS LANDS ON
--
-- `set_vault_pin` has already been replaced once, by
-- `20260818090100_vault_pin_reset_cannot_clear_a_lockout.sql`, which added the
-- `locked` guard. Read `20260601001100_private_vault.sql` alone and you will
-- re-derive a body WITHOUT that guard and silently revert it — which is why the
-- `create or replace` below is written against the live definition (verified
-- 2026-09-09 with pg_get_functiondef on both projects) rather than against the
-- older file.
--
-- RE-RUNNABLE: every statement is `create or replace` or a `revoke`/`grant`. A
-- second run is a no-op.
--
-- ROLLBACK (exact, tested shape — restores the live-as-of-2026-09-09 behaviour):
--
--   drop function if exists public.change_vault_pin(text, text);
--   create or replace function public.set_vault_pin(p_pin text)
--   returns void language plpgsql security definer
--   set search_path = public, extensions as $$
--   declare v_uid uuid := auth.uid();
--   begin
--     if v_uid is null then raise exception 'not_authenticated'; end if;
--     if p_pin !~ '^[0-9]{4}$' then raise exception 'invalid_pin'; end if;
--     if exists (select 1 from public.vault_pin
--                 where user_id = v_uid and locked_until is not null
--                   and locked_until > now()) then
--       raise exception 'locked';
--     end if;
--     insert into public.vault_pin (user_id, pin_hash)
--       values (v_uid, extensions.crypt(p_pin, extensions.gen_salt('bf')))
--     on conflict (user_id) do update
--       set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null;
--   end; $$;
--
-- ───────────────────────────────────────────────────────────────────────────

-- ─── The new verb ──────────────────────────────────────────────────────────
-- Returns 'ok' | 'wrong' | 'locked' | 'no_pin'. A verdict string rather than an
-- exception, matching `verify_vault_pin`, so the client can give each refusal
-- its own sentence instead of parsing an error message.
create or replace function public.change_vault_pin(p_old text, p_new text)
returns text language plpgsql security definer
set search_path = public, extensions as $$
declare v_uid uuid := auth.uid(); r public.vault_pin;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  -- Only the NEW pin's shape is enforced. Validating the old one's shape would
  -- answer "that is not even the right form" without spending an attempt,
  -- which is a free bit of information about the stored PIN.
  if p_new !~ '^[0-9]{4}$' then raise exception 'invalid_pin'; end if;

  -- FOR UPDATE, and it is the lockout that depends on it. Read without the row
  -- lock, every request that arrives before the first one commits sees
  -- locked_until = null and gets its guess evaluated — so the ceiling is not
  -- five attempts per fifteen minutes, it is however many requests fit in the
  -- window. Concurrent callers now queue behind the first writer and see the
  -- lock it wrote.
  select * into r from public.vault_pin where user_id = v_uid for update;
  if not found then return 'no_pin'; end if;
  if r.locked_until is not null and r.locked_until > now() then
    return 'locked';
  end if;

  if r.pin_hash <> extensions.crypt(p_old, r.pin_hash) then
    -- Identical to verify_vault_pin's accounting, writing the same counters, so
    -- guessing through this door is bounded by the same lockout as guessing
    -- through that one.
    update public.vault_pin
       set failed_attempts = failed_attempts + 1,
           locked_until = case when failed_attempts + 1 >= 5
                               then now() + interval '15 minutes' else null end
     where user_id = v_uid;
    return 'wrong';
  end if;

  update public.vault_pin
     set pin_hash        = extensions.crypt(p_new, extensions.gen_salt('bf')),
         failed_attempts = 0,
         locked_until    = null
   where user_id = v_uid;
  return 'ok';
end; $$;
revoke execute on function public.change_vault_pin(text, text) from public, anon;
grant  execute on function public.change_vault_pin(text, text) to authenticated;

-- ─── set_vault_pin becomes first-time-only ─────────────────────────────────
-- Without this the function above is decoration: an attacker skips the door
-- that asks for the old PIN and uses the one that does not.
--
-- Safe for the DEPLOYED client, which cannot be forced to upgrade. Build 83
-- calls set_vault_pin from exactly one place — vault_gate_screen `_onSetupPin`,
-- reachable only when `_hasPin` is false, i.e. when there is no row to
-- conflict with. A client that has a PIN never reaches it.
--
-- The cost, stated plainly: there is now NO path that re-keys a vault whose PIN
-- the owner has forgotten. There was none in the UI before this either, so
-- nothing a user could do has been taken away — but a recovery flow, if one is
-- ever wanted, has to be built deliberately and gated on something other than
-- the PIN. It must never be this function.
create or replace function public.set_vault_pin(p_pin text)
returns void language plpgsql security definer
set search_path = public, extensions as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'invalid_pin'; end if;
  -- Preserved from the live definition, which this repo's own
  -- 20260601001100 file does not have. Dropping it here would silently
  -- re-open a lockout bypass that both projects already closed.
  if exists (
    select 1 from public.vault_pin
     where user_id = v_uid
       and locked_until is not null
       and locked_until > now()
  ) then
    raise exception 'locked';
  end if;
  if exists (select 1 from public.vault_pin where user_id = v_uid) then
    raise exception 'pin_exists';
  end if;
  insert into public.vault_pin (user_id, pin_hash)
    values (v_uid, extensions.crypt(p_pin, extensions.gen_salt('bf')));
end; $$;
revoke execute on function public.set_vault_pin(text) from public, anon;
grant  execute on function public.set_vault_pin(text) to authenticated;

-- ─── verify_vault_pin takes the same row lock ──────────────────────────────
-- Not scope creep: change_vault_pin above writes the SAME failed_attempts and
-- locked_until counters, and its doc claims the two doors share one lockout.
-- That claim is only true if both doors are serialised. Leaving the gate racy
-- would mean a change endpoint carefully bounded to five attempts sitting
-- beside a verify endpoint that can be guessed at concurrently, against the
-- same counter — half a fix, and the half that ships is the one nobody tests.
--
-- Body is otherwise the live definition, unchanged. Contract is unchanged, so
-- the deployed client cannot notice.
create or replace function public.verify_vault_pin(p_pin text)
returns text language plpgsql security definer
set search_path = public, extensions as $$
declare v_uid uuid := auth.uid(); r public.vault_pin;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into r from public.vault_pin where user_id = v_uid for update;
  if not found then return 'no_pin'; end if;
  if r.locked_until is not null and r.locked_until > now() then return 'locked'; end if;
  if r.pin_hash = extensions.crypt(p_pin, r.pin_hash) then
    update public.vault_pin set failed_attempts = 0, locked_until = null where user_id = v_uid;
    return 'ok';
  end if;
  update public.vault_pin
     set failed_attempts = failed_attempts + 1,
         locked_until = case when failed_attempts + 1 >= 5
                             then now() + interval '15 minutes' else null end
   where user_id = v_uid;
  return 'wrong';
end; $$;
revoke execute on function public.verify_vault_pin(text) from public, anon;
grant  execute on function public.verify_vault_pin(text) to authenticated;
