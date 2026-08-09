-- ───────────────────────────────────────────────────────────────────────────
-- Miles — presence delivery, in ONE result set.
--
-- The Supabase SQL editor shows only the LAST statement's output, so the
-- earlier multi-section diagnostics were hiding their first sections. This is
-- a single SELECT: every check is a row, and nothing can be missed.
--
-- Read-only.
-- ───────────────────────────────────────────────────────────────────────────
select * from (

  -- Realtime cannot deliver anything unless the table is published.
  select 1 as ord, 'presence in supabase_realtime publication' as check,
         case when exists (
                select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'presence')
              then 'ok' else '*** MISSING -> no live presence events ***' end as result

  -- Without REPLICA IDENTITY FULL an RLS-filtered UPDATE arrives without the
  -- columns needed to evaluate the row filter, so Supabase drops it silently.
  union all
  select 2, 'presence replica identity FULL',
         case (select relreplident from pg_class where oid = 'public.presence'::regclass)
           when 'f' then 'ok' else '*** NOT FULL -> RLS updates dropped ***' end

  union all
  select 3, 'chat_receipts in publication',
         case when exists (
                select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'chat_receipts')
              then 'ok' else 'MISSING -> receipts will not update live' end

  union all
  select 4, 'messages in publication',
         case when exists (
                select 1 from pg_publication_tables
                 where pubname = 'supabase_realtime'
                   and schemaname = 'public' and tablename = 'messages')
              then 'ok' else '*** MISSING -> no live chat at all ***' end

  -- How many partner rows can each paired user actually resolve under the
  -- SELECT policy? Anything but exactly 1 in a two-person couple is the bug.
  union all
  select 10, 'RLS: ' || me.display_name || ' [' || left(me.id::text, 8) || '] sees',
         coalesce((select string_agg(p2.display_name, ', ')
                     from public.presence pr
                     join public.profiles p2 on p2.id = pr.user_id
                    where pr.couple_id = me.couple_id
                      and pr.user_id <> me.id), '*** NOBODY ***')
         || '  (' || (select count(*)
                        from public.presence pr
                       where pr.couple_id = me.couple_id
                         and pr.user_id <> me.id)::text || ' row(s))'
    from public.profiles me
   where me.couple_id is not null

  -- Realtime is authenticated per-connection; if the anon/authenticated role
  -- cannot SELECT the table at all, the subscription silently yields nothing.
  union all
  select 20, 'authenticated can SELECT presence',
         case when has_table_privilege('authenticated', 'public.presence', 'SELECT')
              then 'ok' else '*** REVOKED -> partner presence unreadable ***' end
  union all
  select 21, 'authenticated can UPDATE presence',
         case when has_table_privilege('authenticated', 'public.presence', 'UPDATE')
              then 'ok' else '*** REVOKED -> own presence unwritable ***' end
  union all
  select 22, 'authenticated can INSERT presence',
         case when has_table_privilege('authenticated', 'public.presence', 'INSERT')
              then 'ok' else '*** REVOKED -> no presence row can be created ***' end

) t order by ord, check;
