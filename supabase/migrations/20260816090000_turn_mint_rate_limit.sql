-- ───────────────────────────────────────────────────────────────────────────
-- Miles — turn-credentials would mint forever.
--
-- The function already refuses anyone without their own JWT, so only people
-- who hold an account can reach it. It never bounded how many times ONE
-- account may ask, and its own comment said so: "that needs a counter this
-- function has nowhere to keep." Every call mints a fresh 24h Cloudflare
-- Realtime TURN credential, and relay traffic is billed by the gigabyte. A
-- signed-in account looping the endpoint runs up an invoice on a project with
-- nobody watching it. This is the counter.
--
-- Identity comes from auth.uid(), not from an argument. The edge function
-- holds the service role, but it calls this on the CALLER's client — the same
-- way it already reads the caller's user — so there is no user id on the wire
-- for anyone to substitute. A client calling this directly can only spend its
-- own quota.
--
-- Ten an hour against a client that caches for 12h and restores a credential
-- up to 20h old from disk (call_controller.dart:448, :479): a normal handset
-- mints once or twice a DAY, so ten leaves room for reinstalls, a second
-- device and a retry storm, and still turns "unbounded" into a number.
--
-- No cron. The function drops its own expired rows on every call and the
-- account cascade takes the rest, so the table is bounded at ten rows per
-- account by construction — a pruning job would have nothing to prune.
--
-- Rollback:
--   drop function if exists public.claim_turn_mint();
--   drop table if exists public.turn_mints;
-- Re-running this file is a no-op: every object is if-not-exists or replace.

create table if not exists public.turn_mints (
  id       bigint generated always as identity primary key,
  user_id  uuid not null references auth.users(id) on delete cascade,
  minted_at timestamptz not null default now()
);

-- Deny-all, exactly like app_secrets: RLS on with no policy means anon and
-- authenticated see nothing, and the service role bypasses RLS to read it.
alter table public.turn_mints enable row level security;
revoke all on public.turn_mints from anon, authenticated;

create index if not exists turn_mints_user_recent_idx
  on public.turn_mints (user_id, minted_at desc);

create or replace function public.claim_turn_mint()
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid    uuid := auth.uid();
  v_recent integer;
begin
  -- No session, no mint. The edge function checks this too; this is the half
  -- that does not depend on the edge function being the only caller.
  if v_uid is null then return false; end if;

  delete from public.turn_mints
   where user_id = v_uid and minted_at < now() - interval '1 hour';

  select count(*) into v_recent
    from public.turn_mints
   where user_id = v_uid and minted_at > now() - interval '1 hour';

  if v_recent >= 10 then return false; end if;

  insert into public.turn_mints (user_id) values (v_uid);
  return true;
end $function$;

-- anon is revoked explicitly, not just via PUBLIC: Supabase's default
-- privileges in this schema grant EXECUTE to anon and authenticated by name,
-- so a bare `revoke ... from public` leaves the named grant standing and anon
-- keeps the privilege. Calling it as anon only ever returns false — auth.uid()
-- is null — but a signed-out role holding EXECUTE on a counter is the kind of
-- grant that stops being harmless when the body changes.
revoke all on function public.claim_turn_mint() from public, anon;
grant execute on function public.claim_turn_mint() to authenticated;
