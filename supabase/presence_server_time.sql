-- ───────────────────────────────────────────────────────────────────────────
-- Miles — presence freshness becomes server-authoritative. Idempotent.
--
-- "Is my partner online" was decided by comparing two phones' clocks:
-- app_last_active_at was stamped by the WRITER'S device, and read against the
-- READER'S DateTime.now() with a 45-second window. Nothing in that comparison
-- ever touched the server.
--
-- Consequences for real users, none of which appear on two NTP-synced phones:
--   * writer's clock >45s SLOW  -> every heartbeat is born already expired.
--     Their partner NEVER sees them online, never sees which screen they are
--     on, and no reinstall fixes it. Permanent and one-sided.
--   * writer's clock FAST       -> difference goes negative, which is always
--     <= 45, so they read as online forever, even with the phone switched off.
--
-- This is the same defect receipts_v2.sql removed from read receipts. Here the
-- server stamps the time on the way in, so a wrong device clock can no longer
-- write a wrong timestamp. (The reader's half is fixed on the client, which
-- learns its offset from the server rather than trusting its own clock.)
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.presence_stamp_server_time()
returns trigger language plpgsql as $$
begin
  -- updated_at is bookkeeping: always the server's clock, never the client's.
  new.updated_at := now();

  -- app_last_active_at drives the online indicator, so it is the one that
  -- must not come from a device. The client still decides WHETHER this write
  -- counts as app activity (it only sends the column for real activity, not
  -- for GPS pings) — but not WHEN. A changed value means "this was activity";
  -- the value itself is discarded and replaced with server time.
  if tg_op = 'INSERT' then
    if new.app_last_active_at is not null then
      new.app_last_active_at := now();
    end if;
  elsif new.app_last_active_at is distinct from old.app_last_active_at then
    new.app_last_active_at := now();
  end if;

  return new;
end $$;

-- SECURITY INVOKER (the default) is correct here: the trigger needs no extra
-- privilege, it only rewrites columns of the row being written.
drop trigger if exists trg_presence_server_time on public.presence;
create trigger trg_presence_server_time
  before insert or update on public.presence
  for each row execute function public.presence_stamp_server_time();

-- Existing rows carry device-stamped values. Anything already outside the
-- window is indistinguishable from "offline" and will self-correct on the next
-- heartbeat; anything in the FUTURE (a fast clock) would otherwise read as
-- online forever, so clamp it.
update public.presence
   set app_last_active_at = now()
 where app_last_active_at > now();

-- ── Proof ─────────────────────────────────────────────────────────────────
-- Writes a deliberately absurd timestamp and shows the server overrode it.
-- Touches only the caller's own row, and leaves it stamped with real now().
do $$
declare v_uid uuid; v_after timestamptz;
begin
  select user_id into v_uid from public.presence limit 1;
  if v_uid is null then
    raise notice 'no presence rows yet — nothing to verify';
    return;
  end if;
  update public.presence
     set app_last_active_at = timestamptz '1999-01-01 00:00:00+00'
   where user_id = v_uid;
  select app_last_active_at into v_after
    from public.presence where user_id = v_uid;
  if v_after > now() - interval '5 seconds' then
    raise notice 'OK: server overrode a 1999 timestamp with % ', v_after;
  else
    raise exception 'TRIGGER NOT WORKING: value stayed at %', v_after;
  end if;
end $$;
