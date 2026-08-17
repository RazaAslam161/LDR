-- Security audit 2026-08-18. memory_threads was the one push path with neither
-- a mute nor a throttle.
--
-- 20260818? (contact_pause_covers_calls_and_memories) gave notify_memory the
-- push_muted guard. This closes the other half: memory_threads had no entry in
-- send_next_allowed_at and no enforce_send_rate trigger, so a scripted client
-- could insert proposals in a loop and each one fired a high-importance FCM
-- push at the partner. reach (30s/5 per 5min), care (30s/10 per hour), calls
-- (15s/10 per 10min) and rewrap (60s/3 per hour) were all already wired; this
-- table was simply missed.
--
-- Chosen limits: 10 second gap, 15 per hour. Deliberately gentler than care's
-- 30s/10 because proposing several memories after a trip is a real thing people
-- do in one sitting, while 15/hour still caps a torture loop hard.
--
-- Three changes, all additive:
--   1. send_next_allowed_at gains a 'memory_threads' branch. Its sender column
--      is `proposer`, not from_user/caller_id. The `else raise exception` arm is
--      untouched, so the whitelist still refuses unknown tables.
--   2. enforce_send_rate's sender lookup gains 'proposer' as a third coalesce
--      fallback. from_user and caller_id keep precedence, so the four triggers
--      already using this function are bit-for-bit unaffected.
--   3. The BEFORE INSERT trigger is scoped `when (new.state = 'proposed')`,
--      matching memory_threads_notify exactly — only inserts that actually send
--      a push are throttled, so non-proposal writes keep working.
--
-- Neither helper is callable by anon or authenticated (proacl is
-- postgres+service_role only), so this adds no REST surface.
--
-- Re-runnable: create or replace, and drop trigger if exists before create.
--
-- Reverse with:
--   drop trigger if exists memory_threads_rate_limit on public.memory_threads;
--   then re-run both functions with the memory_threads branch and the
--   'proposer' coalesce fallback removed.

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
                             to_jsonb(new) ->> 'proposer'))::uuid;
begin
  if public.send_next_allowed_at(tg_table_name, v_sender) > now() then
    -- PostgREST turns a PTxyz sqlstate into HTTP xyz, so the client sees 429
    -- rather than a 500 that looks like the server broke.
    raise exception 'rate_limited' using errcode = 'PT429';
  end if;
  return new;
end $function$;

drop trigger if exists memory_threads_rate_limit on public.memory_threads;
create trigger memory_threads_rate_limit
  before insert on public.memory_threads
  for each row when (new.state = 'proposed')
  execute function public.enforce_send_rate();
