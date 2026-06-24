-- ───────────────────────────────────────────────────────────────────────────
-- Miles — Realtime enablement
-- RUN THIS LAST, after schema.sql + breath_events.sql + reach_pulses.sql.
--
-- Supabase Realtime "postgres-changes" delivers NOTHING unless the table is in
-- the `supabase_realtime` publication. Without this, Reach, Breath Sync, and the
-- partner-online presence dot silently do nothing on the receiving phone even
-- though rows are written correctly. REPLICA IDENTITY FULL ensures RLS-filtered
-- UPDATE events (presence) carry the full row to the subscriber.
-- ───────────────────────────────────────────────────────────────────────────
do $$
declare
  t text;
begin
  foreach t in array array[
    'profiles', 'breath_events', 'reach_pulses',
    -- partner changes that should appear live on the other phone:
    'visits', 'rituals', 'daily_prompts', 'prompt_responses'
  ]
  loop
    execute format('alter table public.%I replica identity full;', t);
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = t
    ) then
      execute format(
        'alter publication supabase_realtime add table public.%I;', t
      );
    end if;
  end loop;
end $$;
