-- call_invites: the caller can ask when they may call again, and the callee
-- can say when they picked up.
--
-- Two months of use: a redial inside the 15s gap that 20260819110000 enforces
-- on call_invites is refused with PT429 AFTER the camera has opened and the
-- offer has been broadcast, and the only sentence the caller ever read blamed
-- the partner ("never answered"). Phase 1 fixed the sentence; this file lets
-- the client ASK before it dials, the way the Reach button has since
-- 20260601007700 (reach_cooldown_seconds). Same shape, same grants, keyed on
-- the LIVE send_next_allowed_at('call_invites', ...) arm (caller_id, 15s,
-- 10 per 10 min) - nothing about the throttle itself changes.
--
-- answered_at: production's call_invites was created by ledger 20260625135757
-- with `status text default 'ringing'` and never received the answered_at the
-- repo's 20260601002000 declares (its CREATE TABLE IF NOT EXISTS was a no-op
-- there; staging took the other file and has answered_at already). No shipped
-- build writes status; all four live rows say 'ringing'. The callee's accept()
-- will stamp answered_at, and handlePendingCall refuses a row that is answered
-- or older than the caller's 35s window - a tapped notification can no longer
-- ring a call nobody is placing. Nullable, no default: build 73's insert names
-- its columns and is unaffected.
--
-- The update grant: like reach_events before 20260906140000, authenticated
-- held table-level UPDATE on every call_invites column under a couple-scoped
-- policy - created_at (the cooldown key), caller_id and offer_sdp included.
-- No shipped build issues an UPDATE on this table at all, so narrowing it to
-- the one column the new code writes costs nobody anything.
--
-- Additive: one nullable column, one new function, a narrowed grant.
-- Re-runnable: add column if not exists, create or replace, revoke/grant are
-- idempotent; the assertions pass again.
--
-- ROLLBACK (paste first if needed; anon never had a legitimate UPDATE and is
-- not restored; the column stays - dropping a column a shipped client may
-- have written is never part of a rollback, and nothing older reads it):
--   drop function if exists public.call_cooldown_seconds();
--   revoke update (answered_at) on public.call_invites from authenticated;
--   grant update on public.call_invites to authenticated;

-- Applied via the Supabase MCP (staging 2026-09-06, production 2026-09-06); production ledger version 20260906121519
-- (apply_migration stamps its own version - the repo prefix is the replay order).

create or replace function public.call_cooldown_seconds()
returns integer language sql stable security definer
set search_path = public as $fn$
  select greatest(0, ceil(extract(epoch from
    coalesce(public.send_next_allowed_at('call_invites', auth.uid()), now()) - now())))::integer;
$fn$;

revoke all on function public.call_cooldown_seconds() from public, anon;
grant execute on function public.call_cooldown_seconds() to authenticated;

alter table public.call_invites add column if not exists answered_at timestamptz;

revoke update on public.call_invites from authenticated, anon;
grant update (answered_at) on public.call_invites to authenticated;

do $do$
begin
  if not has_function_privilege('authenticated', 'public.call_cooldown_seconds()', 'EXECUTE') then
    raise exception 'authenticated cannot execute call_cooldown_seconds()';
  end if;
  if has_function_privilege('anon', 'public.call_cooldown_seconds()', 'EXECUTE') then
    raise exception 'anon can execute call_cooldown_seconds()';
  end if;
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'call_invites'
      and column_name = 'answered_at'
  ) then
    raise exception 'call_invites.answered_at did not land';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'call_invites'
      and cmd in ('UPDATE', 'ALL')
  ) then
    raise exception 'call_invites has no UPDATE policy; answered_at would have nothing to pass';
  end if;
  if not has_column_privilege('authenticated', 'public.call_invites',
                              'answered_at', 'UPDATE') then
    raise exception 'authenticated lost UPDATE on call_invites.answered_at';
  end if;
  if has_column_privilege('authenticated', 'public.call_invites',
                          'created_at', 'UPDATE') then
    raise exception 'authenticated can still UPDATE call_invites.created_at';
  end if;
  if has_column_privilege('authenticated', 'public.call_invites',
                          'offer_sdp', 'UPDATE') then
    raise exception 'authenticated can still UPDATE call_invites.offer_sdp';
  end if;
end $do$;
