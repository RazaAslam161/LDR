-- TRUNCATE ignores row-level security. There is no policy that can stop it and
-- no WHERE clause to scope it: the grant is the whole check.
--
-- Two of forty-six public tables handed it to `authenticated`, and both are the
-- two created most recently — `key_escrow` (006700) and `memory_photos` (007000).
-- The other forty-four had it revoked by an earlier sweep, so this is not a
-- policy anyone chose; it is Supabase's `alter default privileges ... grant all
-- on tables to anon, authenticated` landing on every table made after that
-- sweep ran. The same default is why REFERENCES and TRIGGER are there.
--
-- What it was worth on those two specifically:
--   key_escrow    — every couple's sealed private seed. Truncating it does not
--                   merely delete rows; it removes the only copy of the key that
--                   survives a reinstall, for everyone, permanently. That table
--                   exists precisely because losing the key orphans every
--                   encrypted row a couple has ever written.
--   memory_photos — every couple's memory photographs, in one statement,
--                   bypassing the dual-consent state machine entirely.
--
-- Data-driven, like 006900, so the next table created with the default grants is
-- caught by re-running this rather than by someone remembering.
do $do$
declare r record;
begin
  for r in
    select c.oid::regclass as tbl
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and (has_table_privilege('authenticated', c.oid, 'TRUNCATE')
        or has_table_privilege('authenticated', c.oid, 'REFERENCES')
        or has_table_privilege('authenticated', c.oid, 'TRIGGER')
        or has_table_privilege('anon', c.oid, 'TRUNCATE')
        or has_table_privilege('anon', c.oid, 'REFERENCES')
        or has_table_privilege('anon', c.oid, 'TRIGGER'))
  loop
    execute format('revoke truncate, references, trigger on %s from authenticated, anon', r.tbl);
  end loop;
end $do$;

-- And stop minting them. The default privileges are what re-arm this on every
-- new table, so the sweep above is a cleanup and this is the fix.
alter default privileges in schema public
  revoke truncate, references, trigger on tables from authenticated, anon;

do $do$
declare n int;
begin
  select count(*) into n
    from pg_class c join pg_namespace n2 on n2.oid = c.relnamespace
   where n2.nspname = 'public' and c.relkind = 'r'
     and (has_table_privilege('authenticated', c.oid, 'TRUNCATE')
       or has_table_privilege('anon', c.oid, 'TRUNCATE'));
  if n > 0 then raise exception '% table(s) still grant TRUNCATE to a client role', n; end if;
end $do$;
