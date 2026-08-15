-- A daily ritual that misses one night must not be dead forever.
--
-- deliver_at only ever moves when a row is delivered, and 20260815070944
-- refuses to deliver anything more than an hour past due so a backlog cannot
-- page both handsets at once. Those two rules trap each other: a recurring
-- ritual that slips below the floor stays below it, the worker never touches
-- it again, and nothing else in the schema writes deliver_at. One paused
-- project — this one auto-pauses after a week idle — retires every goodnight
-- and goodmorning on it, silently and permanently. Prod is already in that
-- state: four goodnight rituals, the oldest set for 24 June, none of which the
-- new worker will ever pick up.
--
-- The floor was right about the send and wrong about the row. Roll a stale
-- recurring ritual forward to its next future occurrence without sending
-- anything: no push for the nights that have passed, and tonight's arrives on
-- time. ritual_next_at returns null for custom, so a one-off that was missed
-- stays missed — for those, "already past" is the truth.
create or replace function public.deliver_rituals()
returns integer language plpgsql security definer set search_path = public as $fn$
declare
  v_url text := public.functions_base_url();
  v_sent integer := 0;
  v_at timestamptz;
  r record;
  m record;
begin
  if v_url is null then
    raise warning 'deliver_rituals: FUNCTIONS_BASE_URL unset - no push sent';
    return 0;
  end if;

  for r in
    select id, type, deliver_at from public.rituals
     where not delivered
       and not deleted
       and deliver_at <= now() - interval '1 hour'
       and public.ritual_next_at(type, deliver_at) is not null
     for update skip locked
  loop
    v_at := r.deliver_at;
    while v_at <= now() loop
      v_at := public.ritual_next_at(r.type, v_at);
    end loop;
    update public.rituals set deliver_at = v_at where id = r.id;
  end loop;

  for r in
    update public.rituals s
       set delivered  = (public.ritual_next_at(s.type, s.deliver_at) is null),
           deliver_at = coalesce(
             public.ritual_next_at(s.type, s.deliver_at), s.deliver_at)
     where s.id in (
       select id from public.rituals
        where not delivered
          and not deleted
          and deliver_at <= now()
          and deliver_at >  now() - interval '1 hour'
        order by deliver_at
        for update skip locked
     )
    returning s.id, s.couple_id
  loop
    -- Both partners, addressed one at a time. reach-notify already takes an
    -- explicit recipient (that is how a call reaches its callee), so nothing
    -- in its shared recipient path — used by reach, care, call, message and
    -- memory — had to change to support this.
    for m in
      select id from public.profiles where couple_id = r.couple_id
    loop
      perform net.http_post(
        url := v_url || '/functions/v1/reach-notify',
        body := jsonb_build_object(
                  'kind', 'ritual',
                  'recipient', m.id,
                  'record', jsonb_build_object(
                    'id', r.id, 'couple_id', r.couple_id)),
        headers := jsonb_build_object(
                     'Content-Type', 'application/json',
                     'x-notify-secret', coalesce(public.notify_secret(), ''))
      );
    end loop;
    v_sent := v_sent + 1;
  end loop;

  return v_sent;
end $fn$;

revoke execute on function public.deliver_rituals() from public, anon, authenticated;
