-- Security audit 2026-08-18. The vault PIN lockout was bypassable by the one
-- person it was meant to slow down.
--
-- verify_vault_pin counts failures and sets locked_until = now() + 15 minutes
-- after five wrong guesses, which makes a 4-digit PIN genuinely expensive to
-- brute force. set_vault_pin then undid all of it: its ON CONFLICT branch was
--
--   set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null
--
-- with no proof of the OLD pin, so anyone holding the session could answer a
-- lockout by simply setting a PIN they chose and continuing immediately.
--
-- The guard below refuses while a lockout is live. It deliberately does NOT add
-- an old-PIN parameter: shipped clients call set_vault_pin(p_pin) with one
-- argument (vault_repository.dart:93) and there is no forced update channel, so
-- changing the signature would either break PIN changes in the field or add an
-- overload nobody calls. Requiring the old PIN is a client-gated follow-up.
--
-- Note for whoever does that follow-up: the PIN is a UI gate, not an access
-- control. vault_items is readable over PostgREST by any holder of the session
-- regardless of PIN state (vault_items_select_member is couple-scoped only), so
-- this closes the lockout bypass, not the underlying "session beats PIN" issue.
--
-- setPin lets the exception propagate (it returns the rpc future directly), so
-- a locked user sees an error rather than a silent success.
--
-- Re-runnable: create or replace.
--
-- Reverse by re-running this body with the `locked` block deleted.

create or replace function public.set_vault_pin(p_pin text)
 returns void
 language plpgsql
 security definer
 set search_path to 'public', 'extensions'
as $function$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'invalid_pin'; end if;
  if exists (
    select 1 from public.vault_pin
     where user_id = v_uid
       and locked_until is not null
       and locked_until > now()
  ) then
    raise exception 'locked';
  end if;
  insert into public.vault_pin (user_id, pin_hash)
    values (v_uid, extensions.crypt(p_pin, extensions.gen_salt('bf')))
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null;
end; $function$;
