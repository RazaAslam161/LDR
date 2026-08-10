-- ───────────────────────────────────────────────────────────────────────────
-- Miles — can the partner's presence row actually REACH the other phone?
-- Read-only.
--
-- The rows are healthy: both partners exist, both fresh, same couple, both
-- publishing current_screen. So the write path is fine and the failure is in
-- delivery or in read permission. Three things can silently block it:
--
--   1. the table is not in the supabase_realtime publication -> postgres_changes
--      delivers NOTHING, and the UI falls back to a 15s poll at best
--   2. replica identity is not FULL -> RLS-filtered UPDATE events arrive without
--      the columns needed to pass the row filter, so they are dropped
--   3. RLS denies the SELECT for one side -> that partner reads null forever
-- ───────────────────────────────────────────────────────────────────────────

-- ── 1. Realtime delivery prerequisites ────────────────────────────────────
select 'REALTIME' as section,
       'presence in supabase_realtime publication' as check,
       case when exists (
              select 1 from pg_publication_tables
               where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'presence')
            then 'ok'
            else '*** MISSING -> no live presence events at all ***'
       end as status
union all
select 'REALTIME',
       'presence replica identity is FULL',
       case (select relreplident from pg_class where oid = 'public.presence'::regclass)
         when 'f' then 'ok'
         else '*** NOT FULL -> RLS-filtered updates get dropped ***'
       end
union all
select 'REALTIME',
       'chat_receipts in publication (new receipts)',
       case when exists (
              select 1 from pg_publication_tables
               where pubname = 'supabase_realtime'
                 and schemaname = 'public' and tablename = 'chat_receipts')
            then 'ok' else 'MISSING -> receipts will not update live' end;

-- ── 2. Does RLS actually let each partner read the other? ─────────────────
-- Simulates the policy for every paired user: for each person, how many
-- presence rows OTHER than their own would they be allowed to SELECT?
-- Anything other than 1 for a two-person couple is the bug.
select 'RLS VISIBILITY' as section,
       me.display_name as viewer,
       (select count(*)
          from public.presence pr
         where pr.couple_id = me.couple_id
           and pr.user_id <> me.id)          as partner_rows_visible,
       (select string_agg(p2.display_name, ', ')
          from public.presence pr
          join public.profiles p2 on p2.id = pr.user_id
         where pr.couple_id = me.couple_id
           and pr.user_id <> me.id)          as sees,
       case when (select count(*) from public.presence pr
                   where pr.couple_id = me.couple_id and pr.user_id <> me.id) = 1
            then 'ok'
            else '*** viewer cannot resolve exactly one partner ***'
       end as status
  from public.profiles me
 where me.couple_id is not null
 order by me.couple_id, me.display_name;

-- ── 3. Are the policies themselves what we think they are? ────────────────
select 'POLICIES' as section, policyname, cmd, qual::text as using_expr
  from pg_policies
 where schemaname = 'public' and tablename = 'presence'
 order by cmd, policyname;
