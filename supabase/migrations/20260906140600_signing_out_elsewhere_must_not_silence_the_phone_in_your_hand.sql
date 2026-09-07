-- revoke_other_push_tokens must never clear the profiles token of the install
-- it was told to KEEP.
--
-- Found by an adversarial read of 20260906140300 before build 77 was built, so
-- no handset ever ran it. That file re-mirrored the kept install's token into
-- profiles.fcm_token, which is right, but did it unconditionally:
--
--   select token into v_keep from public.push_tokens
--    where user_id = v_uid and device_id = p_keep_device_id and revoked_at is null;
--   update public.profiles set fcm_token = v_keep, ... where id = v_uid ...;
--
-- v_keep is NULL whenever the ledger holds no live row for this install, and
-- that is an ordinary state, not an error: registerToken() is fire-and-forget
-- on resume, the client's own 24h skip can return before the RPC is ever
-- called (the prefs key survives an in-place update from a build that wrote
-- profiles.fcm_token directly), getToken() can answer null on a GMS hiccup,
-- and notification permission may simply have been refused. In every one of
-- those the account still had a working token in profiles from the previous
-- build — and "Sign out of other devices", whose dialog promises "This phone
-- stays signed in", would null it. The phone in the user's hand goes silent,
-- and the write also lands fcm_token_updated_at = null, which a build-73
-- partner can read.
--
-- The rule the whole ledger is built on: this function may only ever REPLACE
-- the profiles leg with a real token, never erase it. Erasing that column is
-- revoke_push_token's job, and only when it names the token being revoked.
--
-- Additive: one create or replace, same signature, same grants (create or
-- replace preserves the ACL, and the grant is re-issued anyway for a fresh
-- database replaying both files in order). Re-runnable. Nothing else changes.
--
-- ROLLBACK (paste first if needed): re-create the function from
-- 20260906140300 — the same body with the `if v_keep is not null then` guard
-- removed. That restores the defect above, so the only reason to run it is to
-- get back to a known state before replacing it with something else.

-- Applied via the Supabase MCP (staging 2026-09-07, production 2026-09-07); production ledger version 20260906234347
-- (apply_migration stamps its own version - the repo prefix is the replay order).

create or replace function public.revoke_other_push_tokens(p_keep_device_id text)
returns integer language plpgsql security definer set search_path = public as $fn$
declare
  v_uid  uuid := auth.uid();
  v_n    integer;
  v_keep text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  update public.push_tokens
     set revoked_at = now(), revoked_reason = 'signed_out_elsewhere'
   where user_id = v_uid and device_id <> p_keep_device_id and revoked_at is null;
  get diagnostics v_n = row_count;
  -- The profiles leg is the only one build 73 and the legacy send path read,
  -- so it must name the handset that stays. When the ledger has no live row
  -- for that handset yet, whatever is already in the column is the best token
  -- the account has: leave it. A null here silences the phone this button
  -- promises to keep.
  select token into v_keep from public.push_tokens
   where user_id = v_uid and device_id = p_keep_device_id and revoked_at is null;
  if v_keep is not null then
    update public.profiles
       set fcm_token = v_keep, fcm_token_updated_at = now()
     where id = v_uid and fcm_token is distinct from v_keep;
  end if;
  return v_n;
end $fn$;

revoke all on function public.revoke_other_push_tokens(text) from public, anon;
grant execute on function public.revoke_other_push_tokens(text) to authenticated;

do $do$
declare v_def text;
begin
  v_def := coalesce((select pg_get_functiondef(p.oid) from pg_proc p
                      where p.pronamespace = 'public'::regnamespace
                        and p.proname = 'revoke_other_push_tokens'), '');
  if v_def not like '%if v_keep is not null then%' then
    raise exception 'revoke_other_push_tokens can still null the kept profiles token';
  end if;
  if not has_function_privilege('authenticated', 'public.revoke_other_push_tokens(text)', 'EXECUTE') then
    raise exception 'authenticated cannot execute revoke_other_push_tokens';
  end if;
  if has_function_privilege('anon', 'public.revoke_other_push_tokens(text)', 'EXECUTE') then
    raise exception 'anon can execute revoke_other_push_tokens';
  end if;
end $do$;
