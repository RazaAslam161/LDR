-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — enable realtime on the Closer feature tables so the partner sees
-- live updates (the missing piece behind "nothing happens" in Closer).
-- Run after the Closer tables exist.
-- ───────────────────────────────────────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array[
    'vault_items','fantasy_jar_entries','fantasy_jar_reveals',
    'memory_threads','memory_revisits','afterglow_entries','body_map_pins',
    'desire_temps','dice_rolls','dice_tier_consents','mood_lamp',
    'intimacy_prefs','consent_state'
  ] loop
    if exists (select 1 from information_schema.tables
               where table_schema='public' and table_name=t) then
      execute format('alter table public.%I replica identity full', t);
      if not exists (select 1 from pg_publication_tables
          where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end if;
  end loop;
end $$;
