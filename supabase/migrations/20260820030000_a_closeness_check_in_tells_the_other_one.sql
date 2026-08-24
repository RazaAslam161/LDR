-- Recovered from the production ledger on 2026-08-23; never committed.
--
-- Applied to prod `sopictusdonlvuezmfep` as version 20260820002802 on
-- 2026-08-20 00:28 UTC, then lost with the disk that held the working
-- tree. The body below is byte-identical to that ledger's stored
-- statements, md5 verified. The explanatory comment this repo's style
-- asks for is absent because it was never in the ledger: these were
-- applied as bare SQL, so whatever prose sat above them died with the
-- disk.
--
-- Renumbered to 20260820030000 so replay order stays correct against the
-- slot scheme the other files in this directory use.

create or replace function public.notify_closeness()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_url     text := public.functions_base_url();
  v_partner uuid;
begin
  select p.id into v_partner
    from public.profiles p
   where p.couple_id = new.couple_id
     and p.id <> new.user_id
     and not exists (
       select 1 from public.desire_temps d
        where d.couple_id = new.couple_id
          and d.on_date   = new.on_date
          and d.user_id   = p.id
     );

  if v_partner is null then
    return new;
  end if;

  if public.push_muted(new.couple_id, new.user_id, 'closeness') then
    return new;
  end if;

  if v_url is null then
    raise warning 'notify_closeness: FUNCTIONS_BASE_URL unset - no push sent';
    return new;
  end if;

  perform net.http_post(
    url := v_url || '/functions/v1/reach-notify',
    body := jsonb_build_object('kind', 'closeness', 'record', jsonb_build_object(
              'couple_id', new.couple_id, 'from_user', new.user_id)),
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-notify-secret', coalesce(public.notify_secret(), ''))
  );
  return new;
end $fn$;

revoke execute on function public.notify_closeness() from public, anon, authenticated;

drop trigger if exists desire_temps_notify on public.desire_temps;
create trigger desire_temps_notify
  after insert on public.desire_temps
  for each row execute function public.notify_closeness();
