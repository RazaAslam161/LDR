-- Recovered from the production ledger on 2026-08-23; never committed.
--
-- Applied to prod `sopictusdonlvuezmfep` as version 20260820002727 on
-- 2026-08-20 00:27 UTC, then lost with the disk that held the working
-- tree. The body below is byte-identical to that ledger's stored
-- statements, md5 verified. The explanatory comment this repo's style
-- asks for is absent because it was never in the ledger: these were
-- applied as bare SQL, so whatever prose sat above them died with the
-- disk.
--
-- Renumbered to 20260820010000 so replay order stays correct against the
-- slot scheme the other files in this directory use.

create or replace function public.closeness_revealed(p_date date)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select count(*) = 2 and min(d.score) >= 7
    from public.desire_temps d
    join public.profiles p
      on p.id = d.user_id
     and p.couple_id = d.couple_id
   where d.couple_id = (select public.current_user_couple_id())
     and d.on_date   = p_date;
$$;

revoke execute on function public.closeness_revealed(date) from public, anon;
grant  execute on function public.closeness_revealed(date) to authenticated;

drop policy if exists "desire_temps_select_member" on public.desire_temps;
create policy "desire_temps_select_member" on public.desire_temps
  for select using (
    couple_id = (select public.current_user_couple_id())
    and (
      user_id = (select auth.uid())
      or public.closeness_revealed(on_date)
    )
  );

drop policy if exists "desire_temps_insert_member" on public.desire_temps;
create policy "desire_temps_insert_member" on public.desire_temps
  for insert with check (
    couple_id = (select public.current_user_couple_id())
    and user_id = (select auth.uid())
  );

drop policy if exists "desire_temps_update_member" on public.desire_temps;
create policy "desire_temps_update_member" on public.desire_temps
  for update using (
    couple_id = (select public.current_user_couple_id())
    and user_id = (select auth.uid())
  )
  with check (
    couple_id = (select public.current_user_couple_id())
    and user_id = (select auth.uid())
  );

drop policy if exists "desire_temps_delete_member" on public.desire_temps;
create policy "desire_temps_delete_member" on public.desire_temps
  for delete using (
    couple_id = (select public.current_user_couple_id())
    and user_id = (select auth.uid())
  );

revoke delete on public.desire_temps from authenticated, anon;

drop function if exists public.closeness_revealed(uuid, date);

do $do$
begin
  if has_table_privilege('authenticated', 'public.desire_temps', 'DELETE') then
    raise exception 'desire_temps: authenticated still holds DELETE';
  end if;
  if not has_function_privilege('authenticated', 'public.closeness_revealed(date)', 'EXECUTE') then
    raise exception 'closeness_revealed must be EXECUTE-able by the role the policy runs as';
  end if;
  if has_function_privilege('anon', 'public.closeness_revealed(date)', 'EXECUTE') then
    raise exception 'closeness_revealed is on the anon surface';
  end if;
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'closeness_revealed'
       and pg_get_function_identity_arguments(p.oid) = 'p_couple uuid, p_date date'
  ) then
    raise exception 'the two-argument cross-couple oracle is still installed';
  end if;
end $do$;
