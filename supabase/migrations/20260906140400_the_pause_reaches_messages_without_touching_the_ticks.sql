-- The contact pause reaches messages - without touching the ticks.
--
-- 20260817160100 left notify_message alone on the argument that msg_sync
-- "draws nothing anywhere". That was already false the day it was written:
-- since 0fee6cf (build 44) the background handler has posted the coalesced
-- "N new messages" entry from that very wake, on the plain identity both
-- handsets run. So a paused contact's messages kept lighting the shade while
-- their Reaches, nudges and calls did not.
--
-- The wake is NOT suppressed here. Gating it on push_muted would freeze the
-- sender's second grey tick and tell them they are paused (BRAIN 3900-3906,
-- 20260817110000:46-72). The record simply carries one more key, computed
-- where only the definer can compute it (push_muted is service-role only),
-- and the receiving client decides: ack delivery, draw nothing. Build 73 reads
-- type/couple_id/message_id/seq, ignores the key and keeps posting - the
-- accepted mixed-build behaviour.
--
-- Body copied from the LIVE production definition (read 2026-09-06) with the
-- one key added. Trigger message_notify_on_insert stays attached (create or
-- replace keeps it). Re-runnable: create or replace; the assertions pass again.
--
-- ROLLBACK (paste first if needed): re-create notify_message() from
-- 20260817110000:125-162 - the same body without the 'muted' key. The
-- trigger needs no change either way.

-- Applied via the Supabase MCP (staging 2026-09-06, production 2026-09-06); production ledger version 20260906121554
-- (apply_migration stamps its own version - the repo prefix is the replay order).

create or replace function public.notify_message()
returns trigger language plpgsql security definer set search_path = public as $fn$
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
  --
  -- `muted`: whether the RECIPIENT has paused this sender. Only the definer
  -- can ask (push_muted is service-role only), and only the receiving handset
  -- acts on it - the wake, the ack and the ticks are untouched.
  perform net.http_post(
    url := v_url || '/functions/v1/reach-notify',
    body := jsonb_build_object(
      'kind', 'msg_sync',
      'record', jsonb_build_object(
        'id', new.id,
        'couple_id', new.couple_id,
        'sender_id', new.sender_id,
        'seq', new.seq,
        'muted', public.push_muted(new.couple_id, new.sender_id, 'message')
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
-- this file has no prior grant to preserve. Re-issued so both paths land in
-- the same place (20260817110000).
revoke execute on function public.notify_message() from public, anon, authenticated;

do $verify$
declare v_def text;
begin
  if not exists (
    select 1 from pg_trigger
     where tgrelid = 'public.messages'::regclass
       and tgname = 'message_notify_on_insert'
       and not tgisinternal
  ) then
    raise exception 'message_notify_on_insert is not attached to public.messages';
  end if;

  v_def := coalesce((select pg_get_functiondef(p.oid) from pg_proc p
                      where p.pronamespace = 'public'::regnamespace
                        and p.proname = 'notify_message'), '');
  if v_def not like '%msg_sync%' then
    raise exception 'notify_message() is not the msg_sync body';
  end if;
  if v_def not like '%push_muted%' then
    raise exception 'notify_message() does not carry the muted key';
  end if;
  if has_function_privilege('authenticated', 'public.notify_message()', 'EXECUTE') then
    raise exception 'authenticated can execute notify_message()';
  end if;
end $verify$;
