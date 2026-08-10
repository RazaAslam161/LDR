-- ============================================================================
-- Push for care reminders and incoming calls.
--
-- Only `reach_events` had an insert trigger, so only a Reach ever reached a
-- BACKGROUNDED partner. Care reminders and call invites were inserted with a
-- receiving-side handler ready and waiting (firebaseMessagingBackgroundHandler
-- branches on type == 'care' / 'call'), but nothing ever sent those pushes —
-- so a care reminder or an incoming call was silently dropped whenever the
-- other phone was not in the foreground. call_controller.dart even documents a
-- "call-notify" trigger that never existed.
--
-- These two triggers close that gap. Both POST to the same `reach-notify`
-- function, which now branches on `kind` and reads the caller/callee columns a
-- call uses. Payload shape { kind, record } matches the function.
--
-- Run AFTER 20260627_call_invites.sql and fcm_push.sql (needs pg_net +
-- care_nudges + call_invites).
-- ============================================================================

create extension if not exists pg_net;

-- ── Care reminders ──────────────────────────────────────────────────────────
create or replace function public.notify_care()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_url text := public.functions_base_url();
begin
  -- Unconfigured environment: skip the notification, never abort the user's
  -- write. These are AFTER INSERT triggers on messages, reaches and nudges.
  if v_url is null then return new; end if;
  perform net.http_post(
    url := v_url || '/functions/v1/reach-notify',
    body := jsonb_build_object('kind', 'care', 'record', to_jsonb(new)),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  return new;
end;
$$;

drop trigger if exists care_notify_on_insert on public.care_nudges;
create trigger care_notify_on_insert
  after insert on public.care_nudges
  for each row execute function public.notify_care();

-- ── Incoming calls ──────────────────────────────────────────────────────────
-- The durable call_invites row already exists so a closed callee can still
-- fetch the offer and answer (call_controller.ringFromFcm); this makes the ring
-- actually arrive.
create or replace function public.notify_call()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare v_url text := public.functions_base_url();
begin
  -- Unconfigured environment: skip the notification, never abort the user's
  -- write. These are AFTER INSERT triggers on messages, reaches and nudges.
  if v_url is null then return new; end if;
  perform net.http_post(
    url := v_url || '/functions/v1/reach-notify',
    body := jsonb_build_object('kind', 'call', 'record', to_jsonb(new)),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  return new;
end;
$$;

drop trigger if exists call_notify_on_insert on public.call_invites;
create trigger call_notify_on_insert
  after insert on public.call_invites
  for each row execute function public.notify_call();
