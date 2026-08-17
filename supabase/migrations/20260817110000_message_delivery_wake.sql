-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the silent delivery wake. One grey tick becomes two without the
-- recipient touching the phone.
--
-- THE DEFECT. A message sits on one grey tick until the recipient opens the
-- conversation, because ackDelivered() has exactly one call site — the chat
-- screen's catch-up — and opening the chat acks delivered AND read in the same
-- breath. So the sender watches one grey jump straight to two green and never
-- sees "delivered" at all. The server half of the reason is here: nothing tells
-- a backgrounded or offline handset that a message exists.
--
-- WHAT WAS ACTUALLY WRONG, verified against production rather than inferred:
--
--   · public.messages carries ZERO triggers.
--       select tgname from pg_trigger
--        where tgrelid='public.messages'::regclass and not tgisinternal;  → 0 rows
--   · public.notify_message() EXISTS and is orphaned — nothing calls it.
--   · The drop was applied out of band and lives only in the prod ledger, as
--     20260812013012 `no_message_push`. No file here performs it.
--   · 20260601003100 CREATES the trigger, but production was baselined with
--     `migration repair --status applied`, so every 20260601* version can never
--     replay. The repo and production disagree and only production is wrong.
--
-- So: "it was never wired" is wrong, and "the trigger was dropped" is right.
-- This file re-attaches it — pointed at a different payload than the one that
-- was dropped, for the reason below.
--
-- WHY THIS DOES NOT SEND kind 'message'. 20260816140000 tried to restore this
-- by re-attaching the old trigger unchanged. That would push kind 'message',
-- and every handset in the field draws a VISIBLE BANNER for it — the
-- `type == 'message'` branch of firebaseMessagingBackgroundHandler calls
-- showMessageNotification (reach_notifications.dart). The builds are
-- sideloaded with no update channel, so that branch is permanent on phones
-- already out there, and the owner has said repeatedly he does not want message
-- notifications. Restoring 'message' would have handed a banner to every
-- installed handset as a side effect of fixing a tick.
--
-- 'msg_sync' is a kind no shipped client has ever heard of. It falls off the
-- end of that handler's opening allow-list and returns before
-- Firebase.initializeApp — no banner, no channel, no work — and
-- in the foreground it falls past every branch to `if (type != 'reach') return`.
-- An old client therefore does nothing at all with it, which is exactly right:
-- this migration is SAFE TO APPLY BEFORE THE CLIENT HALF SHIPS, and turns on no
-- user-visible behaviour by itself.
--
-- WHY IT IS NOT GATED ON push_muted, contradicting 20260816140000's guard.
-- 20260816140000 refuses to run unless notify_message() consults push_muted().
-- That precondition can never be satisfied — 20260816120000 states in its own
-- body that "notify_message and notify_call are deliberately NOT touched here",
-- and its verify loop covers notify_reach and notify_care only. The guard was
-- written against a version of that migration that does not exist, which is why
-- 20260816140000 has never been applied to anything and would abort a fresh
-- database. It is neutralised in place.
--
-- The gate is also wrong on the merits, not just unsatisfiable:
--
--   · A contact pause suppresses INTERRUPTION. This push interrupts nobody —
--     it draws nothing on any client, present or future. There is no
--     interruption here for the pause to remove.
--   · Gating it would freeze the SENDER's ticks at one grey forever for a
--     paused contact. That is a false statement in the sender's UI: the message
--     did arrive.
--   · Worse, it would leak the pause. A sender whose ticks stop advancing with
--     one specific person, and only that person, has been told they were
--     paused. 20260816120000's whole thesis is that the pause must be invisible
--     to the other side — "a stop the other person can see is one nobody in a
--     controlling relationship can afford to use". A mute-gated receipt is
--     precisely such a stop.
--
--   So: a delivery receipt is not a notification, and is not muted. The pause
--   keeps everything it had — reach and care stay guarded, and the message
--   channel it never covered gains nothing that rings, buzzes or displays.
--
-- WHAT ELSE CHANGED IN THE BODY. The old body posted `to_jsonb(new)` — the
-- entire message row, including `body`, `image_path`, `voice_path` and both
-- mood columns — to the edge function, which read three fields off it. The
-- replacement names the four fields it actually needs. `seq` is new and is the
-- point of the exercise: it is the number the client answers with.
--
-- SECOND RUN: no-op. `create or replace function` rewrites the same body,
-- `drop trigger if exists` + `create trigger` re-creates the same trigger, and
-- the revoke is idempotent. Nothing accumulates and nothing duplicates.
--
-- OLD CLIENTS: unaffected. No column, type or RPC signature changes here; this
-- adds a trigger and rewrites one SECURITY DEFINER trigger function that no
-- client can call (execute is revoked from anon/authenticated below). A client
-- that predates this change receives one extra data push it silently ignores.
--
-- ───────────────────────────────────────────────────────────────────────────
-- ROLLBACK — written before the forward change, and restores exactly the state
-- this file found: no trigger on messages, notify_message() orphaned with its
-- current body byte for byte (captured from pg_get_functiondef on production,
-- 2026-08-17). Safe to run more than once.
--
--   drop trigger if exists message_notify_on_insert on public.messages;
--
--   create or replace function public.notify_message()
--   returns trigger language plpgsql security definer
--   set search_path to 'public' as $rb$
--   declare v_url text := public.functions_base_url();
--   begin
--     if v_url is null then
--       raise warning 'notify_message: FUNCTIONS_BASE_URL unset - no push sent';
--       return new;
--     end if;
--     perform net.http_post(
--       url := v_url || '/functions/v1/reach-notify',
--       body := jsonb_build_object('kind', 'message', 'record', to_jsonb(new)),
--       headers := jsonb_build_object('Content-Type', 'application/json',
--                    'x-notify-secret', coalesce(public.notify_secret(), ''))
--     );
--     return new;
--   end; $rb$;
--
--   revoke execute on function public.notify_message()
--     from public, anon, authenticated;
--
-- Rolling back leaves reach-notify's 'msg_sync' branch deployed and unreachable,
-- which is inert — no caller, no cost. It does not need reverting to restore
-- behaviour.
-- ───────────────────────────────────────────────────────────────────────────

-- ── forward ────────────────────────────────────────────────────────────────

create or replace function public.notify_message()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $fn$
declare v_url text := public.functions_base_url();
begin
  if v_url is null then
    -- Loud, and carrying the row it lost. A delivery wake that silently does
    -- not happen looks identical to a partner who simply has not read the
    -- message yet, so the one place it can be noticed is here.
    raise warning 'notify_message: FUNCTIONS_BASE_URL unset - no delivery wake for message % (couple %)',
      new.id, new.couple_id;
    return new;
  end if;

  -- Named fields, not to_jsonb(new): the wake carries who and which, never
  -- what. `body` is ciphertext and still has no business leaving the database
  -- for a payload that exists to transmit a sequence number.
  perform net.http_post(
    url := v_url || '/functions/v1/reach-notify',
    body := jsonb_build_object(
      'kind', 'msg_sync',
      'record', jsonb_build_object(
        'id', new.id,
        'couple_id', new.couple_id,
        'sender_id', new.sender_id,
        'seq', new.seq
      )
    ),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-notify-secret', coalesce(public.notify_secret(), '')
    )
  );
  return new;
end; $fn$;

-- create or replace preserves the existing ACL, but a fresh database replaying
-- this file has no prior grant to preserve. Re-issued so both paths land in the
-- same place. Matches 20260601003100 and 20260816090100.
revoke execute on function public.notify_message() from public, anon, authenticated;

drop trigger if exists message_notify_on_insert on public.messages;
create trigger message_notify_on_insert
after insert on public.messages
for each row execute function public.notify_message();

-- ── prove it, in the same transaction ──────────────────────────────────────
-- The trigger is the thing this file exists to create; a migration that reports
-- success without it attached is the failure mode that produced 20260812's
-- silent drop in the first place.
do $verify$
begin
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.messages'::regclass
       and tgname = 'message_notify_on_insert'
       and not tgisinternal
  ) then
    raise exception 'message_notify_on_insert did not attach to public.messages';
  end if;

  if coalesce((select pg_get_functiondef(p.oid) from pg_proc p
                where p.pronamespace = 'public'::regnamespace
                  and p.proname = 'notify_message'), '') not like '%msg_sync%' then
    raise exception 'notify_message() is not the msg_sync body - a later create or replace overwrote it';
  end if;
end $verify$;
