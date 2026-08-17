-- Security audit 2026-08-17. Contact pause only ever stopped two of the four
-- things that interrupt someone.
--
-- notify_reach and notify_care open with
--   if public.push_muted(new.couple_id, new.from_user, '<kind>') then return new; end if;
-- and notify_call and notify_memory never had it. push_muted matches
-- `m.kind in (p_kind, 'contact')`, so a paused contact still rang a
-- full-screen-intent call and still fired a high-importance memory push — the
-- two loudest things in the app, aimed at the person who had just asked for
-- quiet. That is the actor this feature exists for.
--
-- notify_message is deliberately NOT changed. It posts kind 'msg_sync', the
-- silent delivery wake: no title, no body, no notification block, and the only
-- thing the receiving client does with it is call ack_delivered(seq). Muting it
-- would interrupt nobody and would break the sender's second grey tick.
--
-- Both bodies below are the live definitions read from production immediately
-- before this was written, with one line added at the top of each and nothing
-- else touched. Re-runnable: create or replace, and the guard is idempotent.
--
-- Reverse by re-running these two bodies with the push_muted line deleted.

create or replace function public.notify_call()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_url text := public.functions_base_url();
begin
  if public.push_muted(new.couple_id, new.caller_id, 'call') then return new; end if;
  if v_url is null then
    raise warning 'notify_call: FUNCTIONS_BASE_URL unset - no ring sent';
    return new;
  end if;
  perform net.http_post(
    url := v_url || '/functions/v1/reach-notify',
    body := jsonb_build_object('kind', 'call', 'record', to_jsonb(new)),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', coalesce(public.notify_secret(), ''))
  );
  return new;
end; $function$;

create or replace function public.notify_memory()
 returns trigger
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare v_url text := public.functions_base_url();
begin
  if public.push_muted(new.couple_id, new.proposer, 'memory') then return new; end if;
  if v_url is null then
    raise warning 'notify_memory: FUNCTIONS_BASE_URL unset - no push sent';
    return new;
  end if;
  perform net.http_post(
    url := v_url || '/functions/v1/reach-notify',
    body := jsonb_build_object('kind', 'memory', 'record', jsonb_build_object(
              'id', new.id, 'couple_id', new.couple_id, 'proposer', new.proposer)),
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-notify-secret', coalesce(public.notify_secret(), ''))
  );
  return new;
end $function$;
