-- Three unrelated leftovers the 2026-09-04 Play-readiness audit named, cleared
-- together because each is a few lines and none touches user content.
--
-- Nothing here drops a column or a table. The self-updater's three columns stay
-- exactly where they are — see section 2 for why — so a client that still
-- selects them keeps reading the shape it expects.

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. Seven dead tables leave the realtime publication.
--
-- afterglow_entries, body_map_pins, fantasy_jar_reveals, memory_revisits,
-- mood_lamp, consent_state and vault_items are read and written by nothing in
-- mobile/lib (grep for each table name returns 0 references, and no
-- subscription names any of them), hold zero rows on production, and were still
-- members of supabase_realtime — so every write anywhere in the database paid
-- to have their replica identity considered.
--
-- vault_items is the one worth naming: it is the DEAD Closer vault. The live
-- vault moved to personal_vault_items at build 60 and nothing has written the
-- old table since.
--
-- Safe for installed clients: a subscriber to a table outside the publication
-- receives no events rather than an error, and with zero rows there were no
-- events to miss.
--
-- ROLLBACK: `alter publication supabase_realtime add table public.<name>;`
-- for each of the seven.
do $$
declare t text;
begin
  foreach t in array array[
    'afterglow_entries', 'body_map_pins', 'fantasy_jar_reveals',
    'memory_revisits', 'mood_lamp', 'consent_state', 'vault_items'
  ] loop
    if exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = t
    ) then
      execute format('alter publication supabase_realtime drop table public.%I', t);
      raise notice 'dropped %% from supabase_realtime', t;
    end if;
  end loop;
end $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. The retired self-updater stops publishing a download URL.
--
-- app_release still carried apk_url, apk_sha256 and latest_version_name from
-- the sideload self-updater, and apk_url was still POPULATED — a public R2
-- object holding build 46's APK, thirty builds stale, reachable by anyone with
-- the link. No client reads any of the three (ReleaseGate's column list never
-- selects them), so the value was pure exposure with no consumer.
--
-- The VALUES are cleared; the COLUMNS stay. Dropping them is a contract change
-- and belongs in its own later migration, after telemetry shows no client
-- selecting them — which is the additive-only rule, and the reason a `select *`
-- from any older build keeps working through this change.
--
-- ROLLBACK: nothing to restore. The URL pointed at a build that must not be
-- installed anyway; if one is ever needed again, write the new value.
update public.app_release
   set apk_url             = null,
       apk_sha256          = null,
       latest_version_name = null
 where apk_url is not null
    or apk_sha256 is not null
    or latest_version_name is not null;

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. dissolution_window gets a fixed search_path.
--
-- The last `function_search_path_mutable` warning on the security advisor. The
-- body is a constant, so the risk is theoretical — but it is called from
-- prune_dissolved_couples, which runs as SECURITY DEFINER on a cron, and a
-- search_path a caller can set is exactly the shape that turns a harmless
-- function into a foothold. Every other function in this schema already pins it.
--
-- IMMUTABLE and the return value are unchanged: still interval '30 days', which
-- is the 30 days the privacy policy's retention table promises.
--
-- ROLLBACK: replay without the `set search_path` line.
create or replace function public.dissolution_window()
returns interval
language sql
immutable
set search_path = public
as $function$ select interval '30 days' $function$;
