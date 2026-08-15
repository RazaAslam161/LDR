-- Rituals actually arrive.
--
-- Until now nothing in the database had ever read rituals.deliver_at. The
-- column was written by the client, the rituals_pending_idx(delivered,
-- deliver_at) index has existed since the first migration, and no query has
-- ever used either: RitualRepository said so in its own docstring ("v1 does
-- not schedule push notifications"). Twenty rituals were set, eighteen came
-- and went in silence.
--
-- A cron worker rather than a trigger, because a ritual is scheduled for the
-- future: there is no write at delivery time for a trigger to hang off.

-- ── Recurrence ──────────────────────────────────────────────────────────────
-- The cadence is the TYPE, not a stored cron expression. rituals.cron exists,
-- is null on every row, and was never written by any client — reading a cron
-- string nobody has ever set would be inventing a feature, so this maps the
-- four enum values the app already offers:
--
--   goodnight / goodmorning  every day
--   weekly_highlow           every 7 days
--   custom                   once (a specific message at a specific moment)
--
-- Advancing by a whole number of days keeps the LOCAL wall-clock time the
-- couple picked. Adding an interval to a timestamptz crosses DST correctly in
-- Postgres, which is the thing a naive "+ 86400 seconds" gets wrong twice a
-- year.
create or replace function public.ritual_next_at(
  p_type public.ritual_type, p_at timestamptz)
returns timestamptz language sql immutable as $fn$
  select case p_type
    when 'goodnight'      then p_at + interval '1 day'
    when 'goodmorning'    then p_at + interval '1 day'
    when 'weekly_highlow' then p_at + interval '7 days'
    else null                              -- custom: fires once, then retires
  end;
$fn$;

-- ── The worker ──────────────────────────────────────────────────────────────
-- Claim-then-send, in one transaction. net.http_post enqueues into
-- net.http_request_queue inside the calling transaction, so if this aborts the
-- claim and the send are rolled back together — a crash loses a push rather
-- than sending one twice, which is the direction to be wrong in.
--
-- The one-hour floor is deliberate. Eighteen rows are already past due, the
-- oldest from June, and a worker with no floor would page both handsets
-- eighteen times on its first tick for rituals that expired weeks ago. They
-- are left exactly as they are: not delivered, not deleted, not falsely
-- marked sent — the app shows them under "already past".
create or replace function public.deliver_rituals()
returns integer language plpgsql security definer set search_path = public as $fn$
declare
  v_url text := public.functions_base_url();
  v_sent integer := 0;
  r record;
  m record;
begin
  if v_url is null then
    raise warning 'deliver_rituals: FUNCTIONS_BASE_URL unset - no push sent';
    return 0;
  end if;

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
revoke execute on function public.ritual_next_at(public.ritual_type, timestamptz)
  from public, anon, authenticated;

-- Every minute: a ritual set for 10:30 that arrives at 11:00 is a broken
-- promise, and the scan is one index probe over a range closed at both ends
-- that returns nothing in the ordinary case.
select cron.unschedule('deliver-rituals')
 where exists (select 1 from cron.job where jobname = 'deliver-rituals');

select cron.schedule('deliver-rituals', '* * * * *',
                     'select public.deliver_rituals();');
