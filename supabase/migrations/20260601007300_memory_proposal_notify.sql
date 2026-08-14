-- Nine proposals. Two couples. Two distinct proposers. Zero acceptances.
--
-- The screen was blamed for that, and the screen is not the reason. Verified:
-- supabase/functions holds exactly care-notify, map-token, reach-notify and
-- turn-credentials, and grepping the whole functions tree for "memory" returns
-- nothing. **A proposal has never fired any notification at all.** The only way
-- to discover one is to open an app disguised as a news reader, pass the app
-- lock, find the ninth tile in the Closer grid, and enter a second PIN. That is
-- a message posted into a locked drawer.
--
-- A database trigger rather than a call from the client, deliberately, and
-- unlike the spec's plan: the insert and the push then succeed or fail
-- together. A client that inserts and is killed on the walk back — which this
-- app invites, because backgrounding raises the disguise cover — would
-- otherwise leave a proposal nobody is ever told about, which is the exact
-- state all nine production rows are in. It also matches every other push
-- here: notify_reach, notify_care and notify_message are all triggers.
--
-- The body carries three plaintext columns rather than to_jsonb(new).
-- reach_events and care_nudges hold nothing sensitive, so the whole-row form
-- was free there; a memory row is title_cipher, note_cipher and — until
-- heal-on-read empties it — photo_cipher, which on one production row is a
-- cleartext JPEG. The function reads only proposer, couple_id and id, but
-- "reads only" is not "receives only", and the difference is a megabyte of a
-- couple's ciphertext travelling through pg_net into a request log for nothing.
create or replace function public.notify_memory()
returns trigger language plpgsql security definer set search_path = public as $fn$
declare v_url text := public.functions_base_url();
begin
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
end $fn$;

revoke execute on function public.notify_memory() from public, anon, authenticated;

-- WHEN (state = 'proposed') because a memory can only be inserted in that
-- state, and saying so keeps a future restore or backfill from paging both
-- partners about rows they already have.
drop trigger if exists memory_threads_notify on public.memory_threads;
create trigger memory_threads_notify
  after insert on public.memory_threads
  for each row when (new.state = 'proposed')
  execute function public.notify_memory();
