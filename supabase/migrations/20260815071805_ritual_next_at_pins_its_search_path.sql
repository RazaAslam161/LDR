-- deliver_rituals pins search_path; the helper it calls did not, and the
-- security advisor flags it. The `when 'goodnight'` arms are compared against
-- public.ritual_type, so the enum is resolved through whatever search_path the
-- caller happens to hold. Every caller today is deliver_rituals, which sets its
-- own -- this closes the case where that stops being true.
create or replace function public.ritual_next_at(
  p_type public.ritual_type, p_at timestamptz)
returns timestamptz language sql immutable set search_path = public as $fn$
  select case p_type
    when 'goodnight'      then p_at + interval '1 day'
    when 'goodmorning'    then p_at + interval '1 day'
    when 'weekly_highlow' then p_at + interval '7 days'
    else null                              -- custom: fires once, then retires
  end;
$fn$;
