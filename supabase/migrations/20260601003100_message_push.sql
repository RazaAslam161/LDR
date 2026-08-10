-- ───────────────────────────────────────────────────────────────────────────
-- Miles — push on new message. Idempotent; safe to re-run.
--
-- Message delivery had exactly ONE transport: the live websocket. Android
-- freezes a backgrounded process, so there is no socket and no timer. The row
-- landed in Postgres, Realtime fanned it out to zero connected subscribers,
-- and it was gone. The recipient was never woken, and — with no catch-up fetch
-- on reconnect — if they were on the Chat tab when they backgrounded, the
-- message never rendered at all on return.
--
-- That is the "she never texted me / the app is broken" symptom.
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.notify_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://sopictusdonlvuezmfep.supabase.co/functions/v1/reach-notify',
    -- {kind, record} is the shape reach-notify branches on; a bare row would
    -- be treated as a "reach" and rejected for having no from_user.
    body := jsonb_build_object('kind', 'message', 'record', to_jsonb(new)),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  return new;
end;
$$;

revoke execute on function public.notify_message() from public, anon, authenticated;

drop trigger if exists message_notify_on_insert on public.messages;
create trigger message_notify_on_insert
after insert on public.messages
for each row execute function public.notify_message();

-- Verifying delivery when it does not work: pg_net is fire-and-forget and
-- swallows the response, so the ONLY place the outcome is visible is
--   select status_code, content, created
--     from net._http_response order by created desc limit 10;
-- A 400 'bad payload' means the deployed reach-notify predates the message
-- branch; a 401/404 means the function is not deployed under that name.
