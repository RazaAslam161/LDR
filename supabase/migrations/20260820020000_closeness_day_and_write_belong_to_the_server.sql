-- Recovered from the production ledger on 2026-08-23; never committed.
--
-- Applied to prod `sopictusdonlvuezmfep` as version 20260820002746 on
-- 2026-08-20 00:27 UTC, then lost with the disk that held the working
-- tree. The body below is byte-identical to that ledger's stored
-- statements, md5 verified. The explanatory comment this repo's style
-- asks for is absent because it was never in the ledger: these were
-- applied as bare SQL, so whatever prose sat above them died with the
-- disk.
--
-- Renumbered to 20260820020000 so replay order stays correct against the
-- slot scheme the other files in this directory use.

create or replace function public.get_closeness()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $fn$
declare
  v_mine      uuid := auth.uid();
  v_my_couple uuid;
  v_today     date := (now() at time zone 'utc')::date;
  v_my_score  int;
  v_partner   int;
  v_revealed  boolean;
  v_out       jsonb;
begin
  if v_mine is null then
    return jsonb_build_object('verdict', 'not_authenticated');
  end if;
  v_my_couple := public.current_user_couple_id();
  if v_my_couple is null then
    return jsonb_build_object('verdict', 'no_couple');
  end if;

  v_revealed := public.closeness_revealed(v_today);

  select max(score) filter (where user_id =  v_mine),
         max(score) filter (where user_id <> v_mine)
    into v_my_score, v_partner
    from public.desire_temps
   where couple_id = v_my_couple and on_date = v_today;

  v_out := jsonb_build_object(
    'verdict',  'ok',
    'on_date',  v_today,
    'mine',     v_my_score,
    'revealed', v_revealed,
    'partner',  case when v_revealed then v_partner else null end
  );

  if v_my_score is null then
    v_out := v_out || jsonb_build_object(
      'partner_checked_in', v_partner is not null
    );
  end if;

  return v_out;
end;
$fn$;

create or replace function public.set_closeness(p_score int)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_mine      uuid := auth.uid();
  v_my_couple uuid;
  v_today     date := (now() at time zone 'utc')::date;
begin
  if v_mine is null then
    return jsonb_build_object('verdict', 'not_authenticated');
  end if;
  if p_score is null or p_score < 1 or p_score > 10 then
    return jsonb_build_object('verdict', 'bad_score');
  end if;
  v_my_couple := public.current_user_couple_id();
  if v_my_couple is null then
    return jsonb_build_object('verdict', 'no_couple');
  end if;

  insert into public.desire_temps (couple_id, on_date, user_id, score)
  values (v_my_couple, v_today, v_mine, p_score)
  on conflict (couple_id, on_date, user_id) do update
     set score = excluded.score;

  return public.get_closeness();
end;
$fn$;

revoke all on function public.get_closeness() from public;
revoke all on function public.get_closeness() from anon;
grant execute on function public.get_closeness() to authenticated;

revoke all on function public.set_closeness(int) from public;
revoke all on function public.set_closeness(int) from anon;
grant execute on function public.set_closeness(int) to authenticated;
