-- Cost- and quota-abuse caps. Three surfaces that had none, all reachable by
-- one signed-in account, none of them fixable from the client.
--
-- Context that decides the numbers: this project is on the Supabase FREE plan.
-- Free does not bill overage — it throttles or, past 500 MB of database, puts
-- the whole project into READ-ONLY. So the damage model here is an OUTAGE, not
-- an invoice, everywhere except Cloudflare TURN, which is billed for real at
-- $0.05/GB after 1,000 GB/month.
--
-- ── 1. TURN: cap how many credentials can be alive at once ─────────────────
-- claim_turn_mint allowed 10 mints/hour/user and turn-credentials issues each
-- with ttl = 86400 (turn-credentials/index.ts:92). Ten an hour that each live
-- a full day means up to 240 simultaneously-valid credentials per account, and
-- NOTHING caps the bytes any of them relay. Cloudflare bills the relay, so that
-- is the one path in this app to a four-figure bill.
--
-- The TTL is the real lever and it cannot move yet: shipped clients cache a
-- credential up to 20h from disk (call_controller.dart:438, :469), so lowering
-- it strands calls on a fleet with no update channel — the function's own
-- comment says to lower it only once min_build enforces a build that caches for
-- less. So this caps CONCURRENCY instead: a daily ceiling alongside the hourly
-- one takes the worst case from ~240 live credentials to 25.
--
-- 25/day is far above real use — a couple places a handful of calls a day — and
-- the hourly limit still shapes bursts. The two together are what bound the
-- bill until the TTL can come down.
--
-- Deliberately NOT changed: the fail-open in turn-credentials/index.ts:57. That
-- is a considered trade (a bill over every call failing the day a migration has
-- not landed) and reversing it is an edge-function deploy, not a migration.
--
-- ── 2. messages: the unrated table wired to two metered surfaces ───────────
-- Every insert fires notify_message() -> net.http_post -> reach-notify -> FCM.
-- reach, care, calls, rewrap and memories all pass through enforce_send_rate;
-- messages never did. A loop is therefore an edge-invocation burn AND a way to
-- wake one specific person's handset all night, which for a couples app in a
-- break-up is the likelier threat than a botnet.
--
-- 600/hour with no minimum gap: a human never approaches one message every six
-- seconds sustained for an hour, and fast back-and-forth typing is untouched
-- because there is no per-message delay. It bounds a scripted account to ~14k
-- invocations/day instead of unbounded. It does NOT make the 500k/month quota
-- safe from many accounts at once — only an edge WAF does that — but it removes
-- the 84-minute kill.
--
-- ── 3. diag_events: the read-only-mode lever ───────────────────────────────
-- Any signed-in account can insert unlimited rows (policy diag_insert_own) with
-- a bare jsonb `fields` column and no rate limit, against a 500 MB ceiling that
-- flips the project read-only. Its neighbour client_errors has had a 10/hour
-- trigger since 20260601007800; diag_events was simply missed. Same shape here,
-- same silent drop — the caller is telemetry and can do nothing with an error.
--
-- Diag is retired (records nothing since build 10; 0 live rows, 13 MB of dead
-- pages) so this costs nothing today. It is a cap on a write surface that is
-- still open, not a fix to a live feature.
--
-- Re-runnable: create or replace, drop-trigger-if-exists before create.
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   drop trigger if exists messages_rate_limit on public.messages;
--   drop trigger if exists diag_events_rate_limit on public.diag_events;
--   drop function if exists public.diag_events_rate_limit();
--   -- then re-run 20260818090200's send_next_allowed_at + enforce_send_rate
--   -- (no 'messages' branch, no sender_id in the coalesce) and 20260816090000's
--   -- claim_turn_mint (hourly cap only).
-- ───────────────────────────────────────────────────────────────────────────

-- 1. TURN ───────────────────────────────────────────────────────────────────
create or replace function public.claim_turn_mint()
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid    uuid := auth.uid();
  v_recent integer;
  v_today  integer;
begin
  if v_uid is null then return false; end if;

  -- Retention widened to a day, because the daily ceiling below needs a day of
  -- history to count. Still self-pruning on every call.
  delete from public.turn_mints
   where user_id = v_uid and minted_at < now() - interval '24 hours';

  select count(*) into v_recent
    from public.turn_mints
   where user_id = v_uid and minted_at > now() - interval '1 hour';
  if v_recent >= 10 then return false; end if;

  -- The ceiling that actually bounds the Cloudflare bill: with ttl = 86400 a
  -- credential stays usable for a day, so the number minted in a day IS the
  -- number that can be relaying traffic simultaneously.
  select count(*) into v_today
    from public.turn_mints
   where user_id = v_uid and minted_at > now() - interval '24 hours';
  if v_today >= 25 then return false; end if;

  insert into public.turn_mints (user_id) values (v_uid);
  return true;
end $function$;

revoke all on function public.claim_turn_mint() from public, anon;
grant execute on function public.claim_turn_mint() to authenticated;

-- 2. messages ───────────────────────────────────────────────────────────────
create or replace function public.send_next_allowed_at(p_table text, p_sender uuid)
 returns timestamp with time zone
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_col text; v_gap interval; v_burst int; v_window interval; v_at timestamptz;
begin
  case p_table
    when 'reach_events' then
      v_col := 'from_user'; v_gap := interval '30 seconds';
      v_burst := 5;  v_window := interval '5 minutes';
    when 'care_nudges' then
      v_col := 'from_user'; v_gap := interval '30 seconds';
      v_burst := 10; v_window := interval '1 hour';
    when 'call_invites' then
      v_col := 'caller_id'; v_gap := interval '15 seconds';
      v_burst := 10; v_window := interval '10 minutes';
    when 'partner_rewrap_requests' then
      v_col := 'from_user'; v_gap := interval '60 seconds';
      v_burst := 3;  v_window := interval '1 hour';
    when 'memory_threads' then
      v_col := 'proposer'; v_gap := interval '10 seconds';
      v_burst := 15; v_window := interval '1 hour';
    when 'messages' then
      -- No gap on purpose: a per-message delay would punish exactly the fast
      -- back-and-forth this app exists for. The hourly ceiling is the bound.
      v_col := 'sender_id'; v_gap := interval '0 seconds';
      v_burst := 600; v_window := interval '1 hour';
    else raise exception 'no send rate defined for %', p_table;
  end case;
  execute format($q$
    select greatest(
      (select max(created_at) from public.%1$I where %2$I = $1) + $2,
      (select created_at from public.%1$I where %2$I = $1
        order by created_at desc offset $3 limit 1) + $4)
  $q$, p_table, v_col)
  into v_at using p_sender, v_gap, v_burst - 1, v_window;
  return v_at;
end $function$;

create or replace function public.enforce_send_rate()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_sender uuid := (coalesce(to_jsonb(new) ->> 'from_user',
                             to_jsonb(new) ->> 'caller_id',
                             to_jsonb(new) ->> 'proposer',
                             to_jsonb(new) ->> 'sender_id'))::uuid;
begin
  if public.send_next_allowed_at(tg_table_name, v_sender) > now() then
    -- PostgREST turns a PTxyz sqlstate into HTTP xyz, so the client sees 429
    -- rather than a 500 that looks like the server broke.
    raise exception 'rate_limited' using errcode = 'PT429';
  end if;
  return new;
end $function$;

drop trigger if exists messages_rate_limit on public.messages;
create trigger messages_rate_limit
  before insert on public.messages
  for each row execute function public.enforce_send_rate();

-- 3. diag_events ────────────────────────────────────────────────────────────
create or replace function public.diag_events_rate_limit()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  -- Mirrors client_errors_rate_limit (20260601007800): true once a tenth row
  -- already exists in the window, so ten an hour land and the eleventh does
  -- not. Dropped silently — the caller is telemetry and would only throw an
  -- error away, and a refused insert costs the same round trip as an accepted
  -- one.
  if exists (
    select 1 from public.diag_events
     where user_id = new.user_id
       and received_at > now() - interval '1 hour'
    offset 9
  ) then
    return null;
  end if;
  return new;
end $fn$;

revoke execute on function public.diag_events_rate_limit()
  from public, anon, authenticated;

drop trigger if exists diag_events_rate_limit on public.diag_events;
create trigger diag_events_rate_limit
  before insert on public.diag_events
  for each row execute function public.diag_events_rate_limit();
