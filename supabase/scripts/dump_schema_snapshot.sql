-- ───────────────────────────────────────────────────────────────────────────
-- Regenerate supabase/schema_snapshot.json.
--
-- The snapshot's own header has told people to run this file since 2026-08-15
-- and the file did not exist — BRAIN §1910 records that it was hand-edited
-- instead. Hand-editing is why it drifted: by 2026-08-26 it was missing 22
-- functions (13 of them nothing to do with the session that noticed) and still
-- listed notify_care_nudge, which 20260815085538 dropped.
--
-- Run it against production and paste the single JSON value it returns over
-- the whole of schema_snapshot.json:
--
--   supabase SQL editor, or the MCP's execute_sql
--   project: sopictusdonlvuezmfep
--
-- It emits the file verbatim, `_comment` and all, so there is nothing to merge
-- by hand and no opportunity to lose a key while doing it.
--
-- WHAT IT DELIBERATELY DOES NOT DO: it does not read staging. staging has been
-- found drifted three separate times (couples.dissolved_at absent,
-- partner_rewrap_requests absent entirely), so a snapshot taken from it would
-- describe a database no user has ever used.
-- ───────────────────────────────────────────────────────────────────────────

with cols as (
  select c.table_name, c.column_name
    from information_schema.columns c
    join information_schema.tables t
      on t.table_schema = c.table_schema and t.table_name = c.table_name
   where c.table_schema = 'public' and t.table_type = 'BASE TABLE'
),
tables as (
  select jsonb_object_agg(table_name, cols) as v from (
    select table_name, jsonb_agg(column_name order by column_name) as cols
      from cols group by table_name
  ) x
),
fns as (
  -- prokind 'f' only: aggregates, window functions and procedures are not
  -- things the client can .rpc().
  select jsonb_agg(distinct p.proname order by p.proname) as v
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
),
upd as (
  -- Only tables where `authenticated` has NO table-level UPDATE. Where it does,
  -- every column is writable and listing them would imply a limit that is not
  -- there.
  select coalesce(jsonb_object_agg(table_name, cols), '{}'::jsonb) as v from (
    select g.table_name, jsonb_agg(g.column_name order by g.column_name) as cols
      from information_schema.role_column_grants g
      -- JOINED to pg_class, not filtered by a WHERE clause. role_column_grants
      -- can name a relation that no longer exists (pg_stat_statements_info on
      -- prod), has_table_privilege RAISES on a dangling name rather than
      -- returning false, and Postgres does not promise to evaluate the
      -- existence test first. A join cannot produce the dangling row at all.
      join pg_class rel
        on rel.relname = g.table_name and rel.relkind = 'r'
      join pg_namespace ns
        on ns.oid = rel.relnamespace and ns.nspname = 'public'
     where g.table_schema = 'public'
       and g.grantee = 'authenticated'
       and g.privilege_type = 'UPDATE'
       and not has_table_privilege('authenticated', rel.oid, 'UPDATE')
     group by g.table_name
  ) y
)
select jsonb_pretty(jsonb_build_object(
  '_comment', jsonb_build_array(
    'The shape of public, as it actually is on sopictusdonlvuezmfep.',
    '',
    'Five times now, client code has shipped against columns that were never',
    'migrated: vault_items.storage_path, memory_threads'' delete quartet,',
    'rituals'' six, and — found by audit rather than by a bug report —',
    'afterglow_entries'' six, where the write threw and the read failed silently.',
    'None of them are catchable by flutter test, because they compile perfectly',
    'and only fail against the real database.',
    '',
    'So the database''s shape is checked in, and schema_drift_test.dart diffs',
    'every column the Dart writes against it. Regenerate with:',
    '  supabase/scripts/dump_schema_snapshot.sql — run it against production',
    '  and paste the single JSON value it returns over this whole file.',
    '',
    'A missing column here is a test failure, not a runtime 403.'
  ),
  'generated_from', current_database(),
  'generated_on', to_char(now(), 'YYYY-MM-DD'),
  'tables', (select v from tables),
  'functions', (select v from fns),
  '_authenticated_update_columns_comment', jsonb_build_array(
    'Tables where `authenticated` holds NO table-level UPDATE, only these columns.',
    'Writing anything else is a 403 at runtime, so the test treats a write to an',
    'ungranted column exactly like a write to a column that does not exist.'
  ),
  'authenticated_update_columns', (select v from upd)
)) as snapshot;
