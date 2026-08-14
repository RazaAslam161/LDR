-- Seventeen tables granted DELETE to authenticated while having no DELETE
-- policy. RLS denied them, so nothing was exposed — but that is one layer, and
-- it is the layer someone removes by adding a permissive policy later without
-- noticing the grant was already sitting there. Same shape as the ops_job_runs
-- finding: deny-all held, on one layer only.
--
-- Data-driven rather than a hand-written list, so a table created tomorrow with
-- Supabase's default grants is caught by re-running this.
do $do$
declare r record;
begin
  for r in
    select c.oid::regclass as tbl
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    left join pg_policy p on p.polrelid = c.oid and p.polcmd = 'd'
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relrowsecurity
      and p.polname is null
      and has_table_privilege('authenticated', c.oid, 'DELETE')
    group by c.oid
  loop
    execute format('revoke delete on %s from authenticated, anon', r.tbl);
  end loop;
end $do$;
